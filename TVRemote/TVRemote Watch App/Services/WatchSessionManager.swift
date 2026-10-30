import Foundation
import WatchConnectivity
import Observation
import os

nonisolated(unsafe) private let log = Logger(subsystem: "gr.orestislef.TVRemote.watchkitapp", category: "WatchSession")

/// The session isn't activated or the phone isn't reachable, so nothing was sent.
private struct PhoneSessionNotReady: Error {}

/// A phone reply, whichever action it answers.
private enum PhoneReply {
    case success(TVStatus?)
    case failure(ConnectionFailure)
}

@Observable
final class WatchSessionManager: NSObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    var pairedDevices: [TVDevice] = []
    var isPhoneReachable = false
    private(set) var hasCertificate = false
    private(set) var activeDevice: TVDevice?
    private(set) var status = TVStatus()
    private(set) var commandFailureCount = 0

    private let tvConnection = WatchTVConnection()

    private let devicesKey = "watch_paired_devices"
    private let lastDeviceKey = "watch_last_device_id"

    @ObservationIgnored private var route: ConnectionRoute?
    /// Bumped on every connect, disconnect and route change. A result from an older value is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var connectInFlight = false
    @ObservationIgnored private var lastReclaimAt: Date?
    @ObservationIgnored private var phoneWatchdog: Task<Void, Never>?
    @ObservationIgnored private var directTask: Task<Void, Never>?
    @ObservationIgnored private var directConnectedAt: Date?
    @ObservationIgnored private var directRetryIndex = 0
    @ObservationIgnored private var isAppActive = true
    /// The app came forward before WCSession finished activating.
    @ObservationIgnored private var resumePending = false
    /// The generation of a getState sent to decide whether to resume the last TV.
    @ObservationIgnored private var resumeCheck: Int?
    /// The active TV came from resuming, not a tap, so the phone may need checking
    /// before it is asked to connect.
    @ObservationIgnored private var isAutoResumed = false

    override init() {
        super.init()
        log.info("WatchSessionManager initializing...")
        hasCertificate = WatchCertificateStore.shared.hasIdentity
        loadCachedDevices()
        tvConnection.onSessionLost = { [weak self] error in
            self?.directSessionLost(error)
        }
        tvConnection.onStateChange = { [weak self] in
            self?.directStateChanged()
        }
        tvConnection.onRemoteError = { [weak self] in
            guard let self, self.route == .direct else { return }
            self.commandFailureCount += 1
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
            log.info("WCSession activated on Watch")
        } else {
            log.warning("WCSession not supported")
        }
    }

    // MARK: - Connection

    func connect(to device: TVDevice) {
        refreshReachability()
        if isAlreadyHandling(device) {
            if activeDevice != device { activeDevice = device }
            return
        }
        startConnecting(device)
    }

    /// Connects to the active or last device now, with a fresh retry budget.
    func retry() {
        guard let device = activeDevice ?? lastDevice else { return }
        refreshReachability()
        startConnecting(device)
    }

    func disconnect() {
        log.info("Disconnecting device")
        let wasOnPhone = route == .viaPhone
        clearRoute()

        refreshReachability()
        if wasOnPhone, isPhoneReachable {
            sendToPhone(["action": "disconnect"], onReply: { _ in }, onError: { error in
                log.warning("Disconnect not delivered: \(error.localizedDescription)")
            })
        }
    }

    private func clearRoute() {
        generation += 1
        connectInFlight = false
        lastReclaimAt = nil
        isAutoResumed = false
        route = nil
        stopDirect()
        activeDevice = nil
        UserDefaults.standard.removeObject(forKey: lastDeviceKey)
        setStatus(TVStatus())
    }

    @discardableResult
    func send(_ command: RemoteCommand) -> Bool {
        guard let device = activeDevice else {
            log.warning("send(\(command.rawValue)): no active device")
            return false
        }
        if route == .direct {
            return tvConnection.sendCommand(command)
        }

        refreshReachability()
        guard isPhoneReachable else {
            connect(to: device)
            return false
        }

        let attempt = generation
        let message: [String: Any] = [
            "action": "command",
            "command": command.rawValue,
            "deviceId": device.id,
        ]
        sendToPhone(message, onReply: { [weak self] reply in
            guard let self, attempt == self.generation else { return }
            switch self.parseReply(reply) {
            case .success(let state):
                if let state { self.applyPhoneState(state) }
            case .failure(let failure):
                log.error("iPhone command failed: \(failure.rawValue)")
                self.commandFailureCount += 1
                if !self.connectInFlight { self.failPhoneRoute(failure) }
                self.refreshDevicesIfPairingFailed(failure)
            }
        }, onError: { [weak self] error in
            guard let self, self.activeDevice?.id == device.id else { return }
            log.error("Command relay error: \(error.localizedDescription)")
            self.commandFailureCount += 1
            guard attempt == self.generation else { return }
            self.refreshReachability()
            if !self.isPhoneReachable || (error as? WCError)?.code == .notReachable {
                self.failPhoneRoute(.phoneUnreachable)
            }
        })
        return true
    }

    private func isAlreadyHandling(_ device: TVDevice) -> Bool {
        guard activeDevice?.id == device.id else { return false }
        switch route {
        case .viaPhone:
            return isPhoneReachable && (status.phase.isConnected || status.phase.isBusy)
        case .direct:
            return directTask != nil || tvConnection.isConnected
        case nil:
            return false
        }
    }

    private func startConnecting(_ device: TVDevice) {
        log.info("Connecting to '\(device.displayName)' phoneReachable=\(self.isPhoneReachable)")
        generation += 1
        connectInFlight = false
        lastReclaimAt = nil
        isAutoResumed = false
        directRetryIndex = 0
        route = nil
        stopDirect()

        var next = activeDevice?.id == device.id ? status : TVStatus()
        next.phase = .connecting
        next.deviceId = device.id
        activeDevice = device
        UserDefaults.standard.set(device.id, forKey: lastDeviceKey)
        setStatus(next)

        // The TV accepts one client and the phone is the only route on real
        // hardware (TN3135), so never try direct while the phone can do it.
        if isPhoneReachable {
            startPhoneRoute(device)
        } else if hasCertificate {
            startDirectRoute(device)
        } else {
            route = .viaPhone
            setPhase(.failed(.phoneUnreachable))
        }
    }

    private func setStatus(_ next: TVStatus) {
        if status != next { status = next }
        updateWatchdog()
    }

    private func setPhase(_ phase: ConnectionPhase) {
        var next = status
        next.phase = phase
        setStatus(next)
    }

    private var lastDevice: TVDevice? {
        guard let id = UserDefaults.standard.string(forKey: lastDeviceKey) else { return nil }
        return pairedDevices.first { $0.id == id }
    }

    // MARK: - Phone route

    private func startPhoneRoute(_ device: TVDevice) {
        route = .viaPhone
        connectInFlight = true
        updateWatchdog()
        let attempt = generation
        sendToPhone(["action": "connect", "deviceId": device.id], onReply: { [weak self] reply in
            guard let self, attempt == self.generation else { return }
            self.connectInFlight = false
            switch self.parseReply(reply) {
            case .success(let state):
                log.info("iPhone connected to '\(device.displayName)'")
                var next = self.status
                if let state, state.deviceId == nil || state.deviceId == device.id { next = state }
                next.phase = .connected(.viaPhone)
                next.deviceId = device.id
                self.setStatus(next)
            case .failure(let failure):
                log.error("iPhone connect failed: \(failure.rawValue)")
                self.setPhase(.failed(failure))
                self.refreshDevicesIfPairingFailed(failure)
            }
        }, onError: { [weak self] error in
            guard let self, attempt == self.generation else { return }
            log.error("iPhone connect message error: \(error.localizedDescription)")
            self.connectInFlight = false
            self.refreshReachability()
            // A timeout from a reachable phone means the TV is slow, not that the
            // phone left. If the phone gets there, its tvState push revives us.
            let timedOut = (error as? WCError)?.code == .messageReplyTimedOut
            self.setPhase(.failed(self.isPhoneReachable && timedOut ? .timeout : .phoneUnreachable))
        })
    }

    /// The phone may have said so because the TV was removed there. The list will
    /// tell, and takes this screen down if so.
    private func refreshDevicesIfPairingFailed(_ failure: ConnectionFailure) {
        if failure == .needsPairing { requestDevices() }
    }

    private func applyPhoneState(_ incoming: TVStatus, phoneInUse: Bool = false) {
        guard route == .viaPhone, let device = activeDevice else { return }

        let isOtherTV = incoming.deviceId != nil && incoming.deviceId != device.id
        if isOtherTV || incoming.phase == .idle {
            // Not about our TV. A connect in flight will settle it with its reply.
            guard !connectInFlight, status.phase.isConnected || status.phase.isBusy else { return }
            if phoneInUse {
                // Someone at the phone disconnected or switched TVs. Their choice
                // stands, so go back to the list and say nothing to the phone.
                log.info("iPhone left '\(device.displayName)' while in use, leaving it")
                clearRoute()
            } else {
                reclaimPhoneRoute(device, isOnOtherTV: isOtherTV)
            }
            return
        }
        // Can be left over from an earlier attempt. The reply is the verdict.
        if connectInFlight, incoming.phase.failure != nil { return }

        var next = incoming
        next.deviceId = device.id
        if !next.phase.isConnected, status.deviceId == device.id {
            if next.volumeLevel == nil {
                next.volumeLevel = status.volumeLevel
                next.isMuted = status.isMuted
            }
            next.volumeMax = next.volumeMax ?? status.volumeMax
        }
        setStatus(next)
    }

    /// The phone left our TV with nobody at it: background time ran out, or the
    /// socket went stale. That is routine, and each connect is bounded by its reply,
    /// so idle can always ask again. Another TV is different: a second switch soon
    /// after means something else wants the phone, and fighting over it helps nobody.
    private func reclaimPhoneRoute(_ device: TVDevice, isOnOtherTV: Bool) {
        if isOnOtherTV {
            if let lastReclaimAt, Date().timeIntervalSince(lastReclaimAt) < ReconnectPolicy.stableSessionSeconds {
                log.warning("iPhone left '\(device.displayName)' for another TV again, giving up")
                clearRoute()
                return
            }
            lastReclaimAt = Date()
        }
        log.info("iPhone is no longer on '\(device.displayName)', asking again")
        generation += 1
        setPhase(.connecting)
        startPhoneRoute(device)
    }

    private func failPhoneRoute(_ failure: ConnectionFailure) {
        generation += 1
        connectInFlight = false
        setPhase(.failed(failure))
    }

    private func phoneWentAway() {
        guard route == .viaPhone, let device = activeDevice else { return }
        guard status.phase.isConnected || status.phase.isBusy else { return }
        log.info("Phone went away while on the phone route")
        generation += 1
        connectInFlight = false
        if hasCertificate {
            setPhase(.reconnecting)
            startDirectRoute(device)
        } else {
            setPhase(.failed(.phoneUnreachable))
        }
    }

    private func pollPhoneState() {
        guard route == .viaPhone, activeDevice != nil, !connectInFlight else { return }
        let attempt = generation
        sendToPhone(["action": "getState"], onReply: { [weak self] reply in
            guard let self, attempt == self.generation else { return }
            if let payload = reply["state"] as? [String: Any], let state = TVStatus(wire: payload) {
                self.applyPhoneState(state, phoneInUse: reply["phoneInUse"] as? Bool ?? false)
            }
        }, onError: { [weak self] error in
            guard let self, attempt == self.generation else { return }
            log.error("getState error: \(error.localizedDescription)")
            self.refreshReachability()
            // A phone slow to wake times out too. The next poll asks again.
            if !self.isPhoneReachable || (error as? WCError)?.code == .notReachable {
                self.failPhoneRoute(.phoneUnreachable)
            }
        })
    }

    /// Pushes are fire and forget, so a lost one must not leave stale state on screen.
    private func updateWatchdog() {
        let shouldRun = route == .viaPhone && isAppActive && (status.phase.isConnected || status.phase.isBusy)
        guard shouldRun else {
            phoneWatchdog?.cancel()
            phoneWatchdog = nil
            return
        }
        guard phoneWatchdog == nil else { return }
        phoneWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.pollPhoneState()
            }
        }
    }

    private func parseReply(_ reply: [String: Any]) -> PhoneReply {
        if let status = reply["status"] as? String, status == "connected" || status == "ok" {
            let state = (reply["state"] as? [String: Any]).flatMap { TVStatus(wire: $0) }
            return .success(state)
        }
        if let message = reply["message"] as? String {
            log.info("iPhone says: \(message)")
        }
        let failure = (reply["failure"] as? String).flatMap { ConnectionFailure(rawValue: $0) }
        return .failure(failure ?? .tvUnreachable)
    }

    private func sendToPhone(
        _ message: [String: Any],
        onReply: @escaping @MainActor ([String: Any]) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        // Sending on an inactive session is a programmer error, not a failed send.
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            onError(PhoneSessionNotReady())
            return
        }
        WCSession.default.sendMessage(message, replyHandler: { reply in
            Task { @MainActor in
                onReply(reply)
            }
        }, errorHandler: { error in
            Task { @MainActor in
                onError(error)
            }
        })
    }

    private func refreshReachability() {
        let reachable = WCSession.isSupported()
            && WCSession.default.activationState == .activated
            && WCSession.default.isReachable
        if isPhoneReachable != reachable { isPhoneReachable = reachable }
    }

    // MARK: - Direct route

    private func startDirectRoute(_ device: TVDevice) {
        route = .direct
        updateWatchdog()
        let attempt = generation
        directTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.tvConnection.connect(to: device)
                guard attempt == self.generation else { return }
                self.directConnected()
            } catch {
                guard attempt == self.generation else { return }
                let connectionError = error as? ConnectionError ?? .cancelled
                log.error("Direct connection failed: \(connectionError.localizedDescription)")
                self.directTask = nil
                self.setPhase(.failed(self.directFailure(for: connectionError)))
            }
        }
    }

    private func directConnected() {
        log.info("Direct connection up")
        directTask = nil
        directConnectedAt = Date()
        setStatus(directStatus(phase: .connected(.direct)))
    }

    private func directSessionLost(_ error: ConnectionError) {
        guard route == .direct, activeDevice != nil else { return }
        log.error("Direct session lost: \(error.localizedDescription)")
        refreshReachability()
        if isPhoneReachable, let device = activeDevice {
            startConnecting(device)
            return
        }
        if let directConnectedAt, Date().timeIntervalSince(directConnectedAt) >= ReconnectPolicy.stableSessionSeconds {
            directRetryIndex = 0
        }
        if error.isTerminal {
            setPhase(.failed(directFailure(for: error)))
            return
        }
        setPhase(.reconnecting)
        retryDirect(after: error)
    }

    private func retryDirect(after error: ConnectionError) {
        let attempt = generation
        directTask?.cancel()
        directTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastError = error
            while self.directRetryIndex < ReconnectPolicy.delays.count {
                let delay = ReconnectPolicy.delays[self.directRetryIndex]
                self.directRetryIndex += 1
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, attempt == self.generation else { return }
                guard let device = self.activeDevice else { return }
                self.refreshReachability()
                if self.isPhoneReachable {
                    self.startConnecting(device)
                    return
                }
                do {
                    try await self.tvConnection.connect(to: device)
                    guard attempt == self.generation else { return }
                    self.directConnected()
                    return
                } catch {
                    guard !Task.isCancelled, attempt == self.generation else { return }
                    lastError = error as? ConnectionError ?? .cancelled
                    log.error("Direct retry failed: \(lastError.localizedDescription)")
                    if lastError.isTerminal { break }
                }
            }
            self.directTask = nil
            self.setPhase(.failed(self.directFailure(for: lastError)))
        }
    }

    private func directStateChanged() {
        guard route == .direct, activeDevice != nil else { return }
        setStatus(directStatus(phase: status.phase))
    }

    private func directStatus(phase: ConnectionPhase) -> TVStatus {
        var next = TVStatus()
        next.phase = phase
        next.deviceId = activeDevice?.id
        next.volumeLevel = tvConnection.volumeLevel
        next.volumeMax = tvConnection.volumeMax
        next.isMuted = tvConnection.volumeMuted
        next.isOn = tvConnection.isTVOn
        next.appLabel = tvConnection.appLabel
        next.appPackage = tvConnection.appPackage
        // The socket forgets these across a reconnect. Keep the last reading until the TV reports again.
        if status.deviceId == next.deviceId {
            if next.volumeLevel == nil {
                next.volumeLevel = status.volumeLevel
                next.isMuted = status.isMuted
            }
            next.volumeMax = next.volumeMax ?? status.volumeMax
            next.isOn = next.isOn ?? status.isOn
            if next.appLabel.isEmpty, next.appPackage.isEmpty {
                next.appLabel = status.appLabel
                next.appPackage = status.appPackage
            }
        }
        return next
    }

    /// Direct can't work on a real Watch, so a direct failure really means the
    /// phone is what's missing. Only a pairing problem is worth saying otherwise.
    private func directFailure(for error: ConnectionError) -> ConnectionFailure {
        error.failure == .needsPairing ? .needsPairing : .phoneUnreachable
    }

    private func stopDirect() {
        directTask?.cancel()
        directTask = nil
        if tvConnection.connectedDeviceId != nil {
            tvConnection.disconnect()
        }
    }

    // MARK: - App lifecycle

    func appDidBecomeActive() {
        isAppActive = true
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            resumePending = true
            return
        }
        refreshReachability()
        requestDevices()
        resumeRoute()
    }

    /// The phone route stays up: the phone owns that session, not this app.
    func appDidResignActive() {
        isAppActive = false
        resumePending = false
        updateWatchdog()
    }

    private func resumeRoute() {
        guard let device = activeDevice else {
            resumeLastDevice()
            return
        }
        switch route {
        case .viaPhone:
            if !isPhoneReachable {
                phoneWentAway()
            } else if status.phase == .failed(.phoneUnreachable) {
                phoneCameBack(for: device)
            } else {
                updateWatchdog()
                pollPhoneState()
            }
        case .direct:
            if isPhoneReachable, !tvConnection.isConnected {
                phoneCameBack(for: device)
            } else if directTask == nil, !tvConnection.isSessionFresh {
                // connect(to:) reuses a socket that still says ready, and this one
                // may have died while suspended, so stopDirect tears it down first.
                startConnecting(device)
            }
        case nil:
            startConnecting(device)
        }
    }

    private func resumeLastDevice() {
        guard let device = lastDevice else { return }
        refreshReachability()
        if isPhoneReachable {
            connectUnlessPhoneInUse(device)
        } else {
            connect(to: device)
            isAutoResumed = true
        }
    }

    private func phoneCameBack(for device: TVDevice) {
        if isAutoResumed {
            connectUnlessPhoneInUse(device)
        } else {
            startConnecting(device)
        }
    }

    /// Nobody tapped anything, so this must not pull the phone off a TV someone is
    /// using on it. If asking fails, connecting will report what is wrong.
    private func connectUnlessPhoneInUse(_ device: TVDevice) {
        guard resumeCheck != generation else { return }
        let attempt = generation
        resumeCheck = attempt
        sendToPhone(["action": "getState"], onReply: { [weak self] reply in
            guard let self, attempt == self.generation else { return }
            self.resumeCheck = nil
            let state = (reply["state"] as? [String: Any]).flatMap { TVStatus(wire: $0) }
            if reply["phoneInUse"] as? Bool == true, let other = state?.deviceId, other != device.id {
                log.info("iPhone is in use on another TV, not resuming '\(device.displayName)'")
                if self.activeDevice != nil { self.clearRoute() }
                return
            }
            self.refreshReachability()
            self.startConnecting(device)
        }, onError: { [weak self] error in
            guard let self, attempt == self.generation else { return }
            log.error("Resume check error: \(error.localizedDescription)")
            self.resumeCheck = nil
            self.refreshReachability()
            self.startConnecting(device)
        })
    }

    // MARK: - Device List

    func requestDevices() {
        refreshReachability()
        guard isPhoneReachable else {
            log.info("Phone not reachable, using cached devices (\(self.pairedDevices.count))")
            return
        }

        log.info("Requesting device list from iPhone")
        sendToPhone(["action": "getDevices"], onReply: { [weak self] reply in
            self?.parseDevicesReply(reply)
        }, onError: { error in
            log.error("getDevices error: \(error.localizedDescription)")
        })
    }

    // MARK: - Certificate Import

    private func importCertificateFromContext(_ context: [String: Any]) {
        guard let keyData = context["privateKeyData"] as? Data,
              let certData = context["certificateData"] as? Data else {
            return
        }
        let store = WatchCertificateStore.shared
        guard !store.hasImported(certificateData: certData) else {
            log.debug("Certificate unchanged, skipping import")
            hasCertificate = true
            return
        }
        log.info("Importing certificate from context: key=\(keyData.count)B cert=\(certData.count)B")
        do {
            try store.importIdentity(privateKeyData: keyData, certificateData: certData)
            log.info("Certificate imported")
        } catch {
            log.error("Certificate import failed: \(error.localizedDescription)")
        }
        hasCertificate = store.hasIdentity
    }

    // MARK: - Parsing & Persistence

    private func applyContext(_ context: [String: Any]) {
        // Certificate first, so the list never publishes without what came with it.
        importCertificateFromContext(context)
        if let devicesData = context["pairedDevices"] as? [[String: Any]] {
            parseDevicesReply(["devices": devicesData])
        }
    }

    private func parseDevicesReply(_ reply: [String: Any]) {
        guard let devicesData = reply["devices"] as? [[String: Any]] else { return }
        pairedDevices = devicesData.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String,
                  let host = dict["host"] as? String,
                  let port = dict["port"] as? Int else { return nil }
            return TVDevice(
                id: id,
                name: name,
                host: host,
                port: port,
                isPaired: true
            )
        }
        log.info("Parsed \(self.pairedDevices.count) paired device(s)")
        cacheDevices()

        guard let active = activeDevice else { return }
        if let updated = pairedDevices.first(where: { $0.id == active.id }) {
            if updated != active { activeDevice = updated }
        } else {
            log.info("Active TV was removed on the iPhone")
            disconnect()
        }
    }

    private func cacheDevices() {
        if let data = try? JSONEncoder().encode(pairedDevices) {
            UserDefaults.standard.set(data, forKey: devicesKey)
            log.debug("Cached \(self.pairedDevices.count) device(s) to UserDefaults")
        }
    }

    private func loadCachedDevices() {
        guard let data = UserDefaults.standard.data(forKey: devicesKey),
              let devices = try? JSONDecoder().decode([TVDevice].self, from: data) else {
            log.info("No cached devices on Watch")
            return
        }
        pairedDevices = devices
        log.info("Loaded \(devices.count) cached device(s) on Watch")
    }

    /// Returns false for an action this side doesn't know.
    private func handlePhoneMessage(_ message: [String: Any]) -> Bool {
        guard let action = message["action"] as? String else { return false }
        switch action {
        case "importCertificate":
            importCertificateFromContext(message)
            return true
        case "tvState":
            if let payload = message["state"] as? [String: Any], let state = TVStatus(wire: payload) {
                applyPhoneState(state, phoneInUse: message["phoneInUse"] as? Bool ?? false)
            }
            return true
        case "commandRejected":
            if route == .viaPhone { commandFailureCount += 1 }
            return true
        default:
            return false
        }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let stateStr = switch activationState {
        case .activated: "activated"
        case .inactive: "inactive"
        case .notActivated: "notActivated"
        @unknown default: "unknown"
        }
        log.info("WCSession activation: \(stateStr)")
        if let error {
            log.error("WCSession activation error: \(error.localizedDescription)")
        }
        Task { @MainActor in
            self.refreshReachability()
            guard activationState == .activated else { return }
            // Load from received application context
            let ctx = session.receivedApplicationContext
            if !ctx.isEmpty {
                self.applyContext(ctx)
            }
            self.requestDevices()
            if self.resumePending || self.activeDevice != nil {
                self.resumePending = false
                self.resumeRoute()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        log.info("Phone reachability changed: \(session.isReachable)")
        Task { @MainActor in
            self.refreshReachability()
            guard self.isPhoneReachable else {
                // Reachability also drops when the Watch app itself goes inactive.
                // appDidBecomeActive sorts that out when it comes back.
                if self.isAppActive { self.phoneWentAway() }
                return
            }
            self.requestDevices()
            if self.activeDevice != nil { self.resumeRoute() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        log.info("Received applicationContext with keys: \(applicationContext.keys.joined(separator: ", "))")
        Task { @MainActor in
            self.applyContext(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        log.info("Received message from iPhone: \(message.keys.joined(separator: ", "))")
        Task { @MainActor in
            if self.handlePhoneMessage(message) {
                replyHandler(["status": "ok"])
            } else {
                replyHandler(["status": "error", "message": "unknown action"])
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        log.debug("Received message (no reply) from iPhone: \(message.keys.joined(separator: ", "))")
        Task { @MainActor in
            _ = self.handlePhoneMessage(message)
        }
    }
}
