import Foundation
import Network
import Observation
import UIKit
import os

private let log = Logger(subsystem: "gr.orestislef.TVRemote", category: "TVManager")

@Observable
final class TVManager {
    var pairedDevices: [TVDevice] = []
    /// The TV we are connected to or trying to reach. Nil when idle.
    private(set) var activeDevice: TVDevice?
    private(set) var phase: ConnectionPhase = .idle
    /// Bumps when the TV rejects something after the handshake. The UI plays a failure haptic.
    private(set) var commandRejectionCount = 0

    let discovery = BonjourDiscovery()
    let pairing = AndroidTVPairing()
    let remoteConnection = AndroidTVConnection()

    /// Fired on any status change. PhoneSessionManager relays it to the Watch.
    @ObservationIgnored var onStatusChange: (() -> Void)?
    /// Fired with `commandRejectionCount`. PhoneSessionManager relays it to the Watch.
    @ObservationIgnored var onCommandRejected: (() -> Void)?
    /// Someone is at the phone, so what it does is their choice and the Watch must not undo it.
    @ObservationIgnored private(set) var isForeground = false

    private let storageKey = "paired_tv_devices"
    private let lastDeviceKey = "last_connected_device_id"
    private let rediscoveryPollCount = 25
    /// Long enough to ride out a Wi-Fi handoff.
    private let networkLossGraceSeconds: Double = 2

    @ObservationIgnored private var lastConnectedDeviceId: String?
    /// The TV asked for last, connected or not. Foregrounding returns to this one.
    @ObservationIgnored private var intendedDeviceId: String?
    /// Bumped whenever an attempt is superseded. A result from an older value is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var connectTask: Task<Void, Error>?
    @ObservationIgnored private var connectingDeviceId: String?
    @ObservationIgnored private var retryIndex = 0
    @ObservationIgnored private var sessionStartedAt: Date?
    @ObservationIgnored private var userDisconnected = false
    @ObservationIgnored private var isNetworkUp = true
    @ObservationIgnored private var keepAliveTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var networkLossTask: Task<Void, Never>?

    // Cellular can't reach the TV, so it must not count as being on the network.
    private let pathMonitor = NWPathMonitor(prohibitedInterfaceTypes: [.cellular])

    init() {
        loadPairedDevices()
        lastConnectedDeviceId = UserDefaults.standard.string(forKey: lastDeviceKey)
        log.info("TVManager ready, \(self.pairedDevices.count) paired device(s) loaded")

        remoteConnection.onSessionLost = { [weak self] error in
            self?.handleSessionLost(error)
        }
        remoteConnection.onStateChange = { [weak self] in
            self?.onStatusChange?()
        }
        remoteConnection.onRemoteError = { [weak self] in
            self?.commandRejected()
        }
        discovery.onDeviceResolved = { [weak self] device in
            self?.applyDiscoveredAddress(device)
        }
        startPathMonitor()
    }

    // MARK: - Status

    var status: TVStatus {
        var status = TVStatus()
        status.phase = phase
        status.deviceId = activeDevice?.id
        // Until the new socket opens, the connection still holds the old TV's readings.
        guard remoteConnection.connectedDeviceId == activeDevice?.id else { return status }
        status.volumeLevel = remoteConnection.volumeLevel
        status.volumeMax = remoteConnection.volumeMax
        status.isMuted = remoteConnection.volumeMuted
        status.isOn = remoteConnection.isTVOn
        status.appLabel = remoteConnection.appLabel
        status.appPackage = remoteConnection.appPackage
        return status
    }

    func phase(for device: TVDevice) -> ConnectionPhase {
        activeDevice?.id == device.id ? phase : .idle
    }

    private var intendedDevice: TVDevice? {
        pairedDevices.first { $0.id == intendedDeviceId }
    }

    private func commandRejected() {
        commandRejectionCount += 1
        onCommandRejected?()
    }

    /// The device to resume with: the last one used, or else the first paired.
    var lastDevice: TVDevice? {
        if let lastConnectedDeviceId,
           let device = pairedDevices.first(where: { $0.id == lastConnectedDeviceId }) {
            return device
        }
        return pairedDevices.first
    }

    // MARK: - Device Management

    /// The stored record for a device. Discovery ids are "ip:port" and change with
    /// the IP, so an entry from discovery is also matched by its mDNS service name.
    func pairedRecord(matching device: TVDevice) -> TVDevice? {
        pairedDevices.first { $0.id == device.id }
            ?? pairedDevices.first { !device.name.isEmpty && $0.name == device.name }
    }

    func addPairedDevice(_ device: TVDevice) {
        if let existing = pairedRecord(matching: device),
           let index = pairedDevices.firstIndex(where: { $0.id == existing.id }) {
            log.info("Updating paired device: '\(device.displayName)' id=\(existing.id)")
            let updated = TVDevice(
                id: existing.id,
                name: device.name,
                host: device.host,
                port: device.port,
                isPaired: true
            )
            pairedDevices[index] = updated
            if activeDevice?.id == updated.id { activeDevice = updated }
        } else {
            log.info("Adding paired device: '\(device.displayName)' id=\(device.id) host=\(device.host):\(device.port)")
            var added = device
            added.isPaired = true
            pairedDevices.append(added)
        }
        savePairedDevices()
    }

    func removePairedDevice(_ device: TVDevice) {
        guard let record = pairedRecord(matching: device) else { return }
        log.info("Removing paired device: '\(record.displayName)' id=\(record.id)")
        pairedDevices.removeAll { $0.id == record.id }
        if lastConnectedDeviceId == record.id { setLastConnectedDevice(nil) }
        if activeDevice?.id == record.id || connectingDeviceId == record.id {
            endSession()
        }
        savePairedDevices()
    }

    // MARK: - Connection

    /// Fire and forget. Same device joins the attempt in flight, another one replaces it.
    func connect(to device: TVDevice) {
        _ = ensureConnecting(to: device)
    }

    func connectAndWait(to device: TVDevice) async throws {
        guard let task = ensureConnecting(to: device) else { return }
        try await task.value
    }

    /// Connects to the active or last device now, with a fresh retry budget.
    func retry() {
        guard let device = activeDevice ?? lastDevice else { return }
        userDisconnected = false
        retryIndex = 0
        if phase == .connecting, connectingDeviceId == device.id { return }
        if phase.isConnected, remoteConnection.isSessionFresh { return }
        _ = startConnecting(to: currentRecord(of: device), lostWith: nil)
    }

    /// User intent: stays idle until asked again, including across foregrounding.
    func disconnect() {
        log.info("Disconnecting from '\(self.activeDevice?.displayName ?? "none")'")
        userDisconnected = true
        endSession()
    }

    @discardableResult
    func sendCommand(_ command: RemoteCommand) -> Bool {
        remoteConnection.sendCommand(command)
    }

    private func ensureConnecting(to device: TVDevice) -> Task<Void, Error>? {
        let device = currentRecord(of: device)
        userDisconnected = false
        if connectingDeviceId == device.id, let connectTask { return connectTask }
        if phase.isConnected, activeDevice?.id == device.id, remoteConnection.isSessionFresh { return nil }
        retryIndex = 0
        return startConnecting(to: device, lostWith: nil)
    }

    private func startConnecting(to device: TVDevice, lostWith loss: ConnectionError?) -> Task<Void, Error> {
        log.info("Connecting to '\(device.displayName)' host=\(device.host):\(device.port)")
        generation += 1
        let attempt = generation
        connectTask?.cancel()
        connectingDeviceId = device.id
        intendedDeviceId = device.id
        activeDevice = device
        setPhase(loss == nil ? .connecting : .reconnecting)

        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { throw ConnectionError.cancelled }
            try await self.runConnection(to: device, attempt: attempt, lostWith: loss)
        }
        connectTask = task
        return task
    }

    private func runConnection(to device: TVDevice, attempt: Int, lostWith loss: ConnectionError?) async throws {
        // Replaced before this task got to run: don't touch the other TV at all.
        guard attempt == generation else { throw ConnectionError.cancelled }

        // A socket gone quiet across a suspension can still look ready, and
        // connect() would reuse it.
        if remoteConnection.isConnected, !remoteConnection.isSessionFresh {
            remoteConnection.dropSocket()
        }

        var mayRediscover = true
        var lastError = loss

        if loss == nil {
            let outcome = await attemptConnection(to: device, attempt: attempt, mayRediscover: &mayRediscover)
            guard attempt == generation else { throw ConnectionError.cancelled }
            guard let error = outcome else {
                didConnect(to: device)
                return
            }
            // The TV dropping us mid-handshake is often it still holding the old
            // session, so confirm before saying the pairing is gone.
            guard error == .closedBeforeHandshake || error == .sessionLost else {
                didFail(with: error)
                throw error
            }
            lastError = error
            setPhase(.reconnecting)
        }

        // Background time is short and the Watch is waiting on the answer, so it
        // gets one quick try instead of the whole budget.
        var backgroundTriesLeft = 1
        while retryIndex < ReconnectPolicy.delays.count {
            if !isForeground {
                guard backgroundTriesLeft > 0 else { break }
                backgroundTriesLeft -= 1
            }
            let delay = ReconnectPolicy.delays[retryIndex]
            retryIndex += 1
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                throw ConnectionError.cancelled
            }
            guard attempt == generation else { throw ConnectionError.cancelled }

            let outcome = await attemptConnection(to: device, attempt: attempt, mayRediscover: &mayRediscover)
            guard attempt == generation else { throw ConnectionError.cancelled }
            guard let error = outcome else {
                didConnect(to: device)
                return
            }
            lastError = error
            if error.isTerminal { break }
        }

        var finalError = lastError ?? .sessionLost
        // One retry can't tell a forgotten pairing from a TV still holding the old
        // session, and only a rejected certificate is sure. Leave it retryable.
        if !isForeground, finalError == .closedBeforeHandshake { finalError = .sessionLost }
        didFail(with: finalError)
        throw finalError
    }

    /// One try, plus one more if the TV turns out to have moved to a new address.
    /// Returns nil on success.
    private func attemptConnection(
        to device: TVDevice,
        attempt: Int,
        mayRediscover: inout Bool
    ) async -> ConnectionError? {
        guard isNetworkUp else { return .noNetwork }
        let target = currentRecord(of: device)
        do {
            try await remoteConnection.connect(to: target)
            return nil
        } catch {
            let failure = connectionError(from: error)
            guard attempt == generation, mayRediscover, failure.mayMeanAddressChanged else { return failure }
            mayRediscover = false

            guard let moved = await findMovedAddress(of: target, attempt: attempt) else { return failure }
            guard attempt == generation else { return .cancelled }
            log.info("'\(moved.displayName)' moved to \(moved.host):\(moved.port), trying again")
            do {
                try await remoteConnection.connect(to: moved)
                return nil
            } catch {
                return connectionError(from: error)
            }
        }
    }

    private func connectionError(from error: Error) -> ConnectionError {
        error as? ConnectionError ?? .unreachable(error.localizedDescription)
    }

    private func didConnect(to device: TVDevice) {
        log.info("Connected to '\(device.displayName)'")
        connectTask = nil
        connectingDeviceId = nil
        sessionStartedAt = Date()
        activeDevice = currentRecord(of: device)
        setLastConnectedDevice(device.id)
        setPhase(.connected(.direct))
    }

    private func didFail(with error: ConnectionError) {
        log.error("Giving up on connection: \(error.localizedDescription)")
        connectTask = nil
        connectingDeviceId = nil
        setPhase(.failed(error.failure))
    }

    private func handleSessionLost(_ error: ConnectionError) {
        guard let device = activeDevice else { return }
        if let sessionStartedAt,
           Date().timeIntervalSince(sessionStartedAt) >= ReconnectPolicy.stableSessionSeconds {
            retryIndex = 0
        }
        sessionStartedAt = nil

        // No retries from the background: the next Watch request or foregrounding
        // reconnects, and an idle state tells the Watch to ask again.
        guard isForeground else {
            log.info("Session lost in background")
            endSession()
            return
        }
        guard !error.isTerminal else {
            didFail(with: error)
            return
        }
        guard isNetworkUp else {
            didFail(with: .noNetwork)
            return
        }
        log.info("Session lost: \(error.localizedDescription), reconnecting")
        _ = startConnecting(to: currentRecord(of: device), lostWith: error)
    }

    /// Stops the attempt and socket and goes idle. Says nothing about user intent,
    /// so foregrounding can resume.
    private func endSession() {
        cancelAttempt()
        endKeepAlive()
        sessionStartedAt = nil
        remoteConnection.disconnect()
        activeDevice = nil
        setPhase(.idle)
    }

    private func cancelAttempt() {
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        connectingDeviceId = nil
    }

    private func setPhase(_ newPhase: ConnectionPhase) {
        phase = newPhase
        onStatusChange?()
    }

    private func currentRecord(of device: TVDevice) -> TVDevice {
        pairedDevices.first { $0.id == device.id } ?? device
    }

    private func setLastConnectedDevice(_ id: String?) {
        lastConnectedDeviceId = id
        UserDefaults.standard.set(id, forKey: lastDeviceKey)
    }

    // MARK: - App lifecycle

    func appDidBecomeActive() {
        isForeground = true
        endKeepAlive()
        PhoneSessionManager.shared.refreshStatus()

        if phase.isConnected {
            guard !remoteConnection.isSessionFresh, let device = activeDevice else { return }
            log.info("Session went quiet while away, reconnecting")
            retryIndex = 0
            _ = startConnecting(to: currentRecord(of: device), lostWith: nil)
            return
        }
        // A rejected certificate won't fix itself, and the screen already offers Pair Again.
        guard connectTask == nil, !userDisconnected, phase.failure != .needsPairing else { return }
        guard let device = activeDevice ?? intendedDevice ?? lastDevice else { return }
        connect(to: device)
    }

    func appDidEnterBackground() {
        isForeground = false
        discovery.stopDiscovery()
        PhoneSessionManager.shared.refreshStatus()

        let watchIsUsingUs = PhoneSessionManager.shared.isReachable
        switch phase {
        case .connected, .connecting:
            if watchIsUsingUs {
                beginKeepAlive()
            } else {
                endSession()
            }
        case .reconnecting:
            endSession()
        case .idle, .failed:
            break
        }
    }

    /// The Watch left this TV. A phone in active use keeps its session.
    func watchRequestedDisconnect() {
        guard !isForeground else { return }
        endSession()
    }

    /// A Watch asking for state after the phone slept must not be told a dead
    /// socket is connected. Going idle makes it ask to connect again.
    func dropStaleSessionIfBackgrounded() {
        guard !isForeground, phase.isConnected, !remoteConnection.isSessionFresh else { return }
        log.info("Dropping session that went quiet in background")
        endSession()
    }

    /// Background time ran out. With the Watch still up, leave the socket alone:
    /// its next press finds the session stale and reconnects, with no idle flicker.
    func backgroundTimeDidEnd() {
        guard !isForeground, keepAliveTask == .invalid, !PhoneSessionManager.shared.isHoldingBackgroundTime else { return }
        PhoneSessionManager.shared.refreshStatus()
        guard !PhoneSessionManager.shared.isReachable else { return }
        guard phase.isConnected || phase == .connecting else { return }
        log.info("Background time ended, closing the TV session")
        endSession()
    }

    private func beginKeepAlive() {
        guard keepAliveTask == .invalid else { return }
        keepAliveTask = UIApplication.shared.beginBackgroundTask(withName: "TVSessionKeepAlive") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endKeepAlive()
                self.backgroundTimeDidEnd()
            }
        }
    }

    private func endKeepAlive() {
        guard keepAliveTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(keepAliveTask)
        keepAliveTask = .invalid
    }

    // MARK: - Network

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isUp = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.networkChanged(isUp: isUp)
            }
        }
        pathMonitor.start(queue: .main)
    }

    private func networkChanged(isUp: Bool) {
        isNetworkUp = isUp
        networkLossTask?.cancel()
        networkLossTask = nil
        guard isUp else {
            if phase == .reconnecting {
                log.info("Network went away while reconnecting")
                cancelAttempt()
                remoteConnection.disconnect()
                setPhase(.failed(.noWiFi))
            } else if phase.isConnected {
                // A socket can keep saying ready after the path drops, and nothing
                // else would correct the screen until the silence watchdog fires.
                networkLossTask = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .seconds(self.networkLossGraceSeconds))
                    guard !Task.isCancelled else { return }
                    self.networkStayedDown()
                }
            }
            return
        }
        guard isForeground, let failure = phase.failure, failure == .noWiFi || failure == .tvUnreachable else { return }
        log.info("Network is back, retrying")
        retry()
    }

    private func networkStayedDown() {
        guard !isNetworkUp, phase.isConnected else { return }
        log.info("Network stayed down, ending the session")
        guard isForeground else {
            endSession()
            return
        }
        cancelAttempt()
        remoteConnection.disconnect()
        setPhase(.failed(.noWiFi))
    }

    // MARK: - IP changes

    /// Browses for a few seconds. Discovery updates the record through
    /// `applyDiscoveredAddress`, so this only has to watch for the change.
    private func findMovedAddress(of device: TVDevice, attempt: Int) async -> TVDevice? {
        guard !device.name.isEmpty, pairedDevices.contains(where: { $0.id == device.id }) else { return nil }
        discovery.startProbe()
        defer { discovery.stopProbe() }

        for _ in 0..<rediscoveryPollCount {
            try? await Task.sleep(for: .milliseconds(200))
            guard attempt == generation else { return nil }
            let current = currentRecord(of: device)
            if current.host != device.host || current.port != device.port { return current }
        }
        return nil
    }

    private func applyDiscoveredAddress(_ found: TVDevice) {
        guard !found.name.isEmpty,
              let index = pairedDevices.firstIndex(where: { $0.name == found.name }) else { return }
        guard pairedDevices[index].host != found.host || pairedDevices[index].port != found.port else { return }

        log.info("'\(found.displayName)' is now at \(found.host):\(found.port)")
        pairedDevices[index].host = found.host
        pairedDevices[index].port = found.port
        if activeDevice?.id == pairedDevices[index].id { activeDevice = pairedDevices[index] }
        savePairedDevices()
    }

    // MARK: - Pairing Flow

    func startPairing(device: TVDevice) async throws {
        log.info("Starting pairing flow for '\(device.displayName)' host=\(device.host) pairingPort=\(device.pairingPort)")
        try await pairing.startPairing(device: device)
    }

    func submitPairingCode(_ code: String, device: TVDevice) async throws {
        log.info("Submitting pairing code for '\(device.displayName)'")
        try await pairing.submitCode(code)
        addPairedDevice(device)
    }

    // MARK: - Persistence

    private func savePairedDevices() {
        if let data = try? JSONEncoder().encode(pairedDevices) {
            UserDefaults.standard.set(data, forKey: storageKey)
            log.info("Saved \(self.pairedDevices.count) paired device(s) to UserDefaults")
        } else {
            log.error("Failed to encode paired devices for storage")
        }
        PhoneSessionManager.shared.sendPairedDevicesToWatch()
    }

    private func loadPairedDevices() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            log.info("No paired devices data in UserDefaults")
            return
        }
        guard let devices = try? JSONDecoder().decode([TVDevice].self, from: data) else {
            log.error("Failed to decode paired devices from UserDefaults")
            return
        }
        pairedDevices = devices
    }

    // MARK: - Watch Data

    func pairedDevicesPayload() -> [[String: Any]] {
        pairedDevices.map { device in
            [
                "id": device.id,
                "name": device.name,
                "host": device.host,
                "port": device.port,
                "isPaired": device.isPaired,
            ] as [String: Any]
        }
    }
}

private extension ConnectionError {
    /// The address on file may be stale, so it's worth looking the TV up by name.
    var mayMeanAddressChanged: Bool {
        switch self {
        case .timeout, .unreachable: return true
        default: return false
        }
    }
}
