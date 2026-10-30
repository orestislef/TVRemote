import Foundation
import UIKit
import WatchConnectivity
import Observation
import os

nonisolated(unsafe) private let log = Logger(subsystem: "gr.orestislef.TVRemote", category: "PhoneSession")

/// Long enough to survive a slow TV, short enough to answer before WC gives up.
private let relayWaitSeconds: Double = 20
/// Refreshed by every Watch message. iOS allows roughly 30s of background time.
private let backgroundHoldSeconds: Double = 25
private let statePushInterval: Duration = .milliseconds(100)

/// Calls a Watch reply handler at most once. A nil handler means the Watch didn't ask for a reply.
private final class WatchReply {
    private var handler: (([String: Any]) -> Void)?

    init(_ handler: (([String: Any]) -> Void)?) {
        self.handler = handler
    }

    func send(_ payload: [String: Any]) {
        handler?(payload)
        handler = nil
    }
}

/// Resumes a continuation once, whichever of the attempt and the timer finishes first.
private final class ConnectionWait {
    private var continuation: CheckedContinuation<ConnectionFailure?, Never>?

    init(_ continuation: CheckedContinuation<ConnectionFailure?, Never>) {
        self.continuation = continuation
    }

    func finish(_ failure: ConnectionFailure?) {
        continuation?.resume(returning: failure)
        continuation = nil
    }
}

@Observable
final class PhoneSessionManager: NSObject, WCSessionDelegate {
    static let shared = PhoneSessionManager()

    @ObservationIgnored var tvManager: TVManager? {
        didSet {
            tvManager?.onStatusChange = { [weak self] in
                self?.scheduleStatePush()
            }
            tvManager?.onCommandRejected = { [weak self] in
                self?.pushCommandRejected()
            }
            sendPairedDevicesToWatch()
        }
    }

    var isPaired = false
    var isWatchAppInstalled = false
    var isReachable = false

    @ObservationIgnored private var holdTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var holdTimer: Task<Void, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var lastPushedStatus: TVStatus?
    /// Commands run one at a time so a burst during a reconnect keeps its order.
    @ObservationIgnored private var commandChain: Task<Void, Never>?
    /// Commands queued behind a failed reconnect share its result instead of each trying again.
    @ObservationIgnored private var lastRelayFailure: (at: Date, failure: ConnectionFailure)?

    /// True while a Watch message is keeping the app running.
    var isHoldingBackgroundTime: Bool {
        holdTask != .invalid
    }

    override init() {
        super.init()
        log.info("PhoneSessionManager initializing...")
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
            log.info("WCSession activated")
        } else {
            log.warning("WCSession not supported on this device")
        }
    }

    func refreshStatus() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let oldPaired = isPaired
        let oldInstalled = isWatchAppInstalled
        let oldReachable = isReachable
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
        if isPaired != oldPaired || isWatchAppInstalled != oldInstalled || isReachable != oldReachable {
            log.info("Watch status changed: paired=\(self.isPaired) installed=\(self.isWatchAppInstalled) reachable=\(self.isReachable)")
        }
    }

    func openWatchAppSettings() {
        log.info("Opening Apple Watch companion app via itms-watchs://")
        if let url = URL(string: "itms-watchs://") {
            UIApplication.shared.open(url)
        }
    }

    /// Publishes the TV list and certificate. Skipped when the Watch already has this
    /// exact context, so activation and repeat saves don't re-export the key.
    func sendPairedDevicesToWatch(force: Bool = false) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            log.info("sendPairedDevicesToWatch: session not activated yet")
            return
        }
        guard let tvManager else {
            log.warning("sendPairedDevicesToWatch: tvManager is nil")
            return
        }

        var context: [String: Any] = [
            "pairedDevices": tvManager.pairedDevicesPayload()
        ]
        if let keyData = CertificateManager.shared.getPrivateKeyData(),
           let certData = CertificateManager.shared.getClientCertificateData() {
            context["privateKeyData"] = keyData
            context["certificateData"] = certData
        } else {
            log.warning("TLS identity not available, Watch will need iPhone for commands")
        }

        if !force, (context as NSDictionary).isEqual(session.applicationContext as NSDictionary) {
            log.debug("applicationContext unchanged, nothing to send")
            return
        }
        do {
            try session.updateApplicationContext(context)
            log.info("Sent \(tvManager.pairedDevices.count) paired device(s) to Watch via applicationContext")
        } catch {
            log.error("Failed to update applicationContext: \(error.localizedDescription)")
        }
    }

    // MARK: - tvState push

    /// At most one push per interval, carrying whatever is latest when it fires.
    private func scheduleStatePush() {
        guard pushTask == nil else { return }
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: statePushInterval)
            guard let self else { return }
            self.pushTask = nil
            self.pushStateNow()
        }
    }

    private func pushStateNow() {
        guard WCSession.isSupported(), let tvManager else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }

        let status = tvManager.status
        guard status != lastPushedStatus else { return }
        lastPushedStatus = status

        session.sendMessage(
            ["action": "tvState", "state": status.wirePayload, "phoneInUse": tvManager.isForeground],
            replyHandler: nil,
            errorHandler: { [weak self] error in
                log.debug("tvState push failed: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.lastPushedStatus = nil
                }
            }
        )
    }

    private func pushCommandRejected() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["action": "commandRejected"], replyHandler: nil, errorHandler: { error in
            log.debug("commandRejected push failed: \(error.localizedDescription)")
        })
    }

    // MARK: - Background time

    /// A Watch message may have woken us. Keep running long enough to finish the
    /// work and answer the next press without paying for a new connection.
    private func holdBackgroundTime() {
        if holdTask == .invalid {
            holdTask = UIApplication.shared.beginBackgroundTask(withName: "WatchRelay") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.endBackgroundHold()
                }
            }
        }
        holdTimer?.cancel()
        holdTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(backgroundHoldSeconds))
            guard !Task.isCancelled, let self else { return }
            self.endBackgroundHold()
        }
    }

    private func endBackgroundHold() {
        holdTimer?.cancel()
        holdTimer = nil
        guard holdTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(holdTask)
        holdTask = .invalid
        tvManager?.backgroundTimeDidEnd()
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
        if let error {
            log.error("WCSession activation completed: \(stateStr), error: \(error.localizedDescription)")
        } else {
            log.info("WCSession activation completed: \(stateStr)")
        }
        Task { @MainActor in
            self.refreshStatus()
            if activationState == .activated {
                self.sendPairedDevicesToWatch()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        log.info("WCSession became inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        log.info("WCSession deactivated, reactivating...")
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        log.info("Watch state changed: paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)")
        Task { @MainActor in
            let wasInstalled = self.isWatchAppInstalled
            self.refreshStatus()
            // A fresh install has lost whatever context we sent the old one.
            if self.isWatchAppInstalled, !wasInstalled {
                self.sendPairedDevicesToWatch(force: true)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        log.info("Watch reachability changed: \(session.isReachable)")
        Task { @MainActor in
            self.refreshStatus()
            if self.isReachable {
                self.lastPushedStatus = nil
                self.scheduleStatePush()
            } else if !self.isHoldingBackgroundTime {
                self.tvManager?.backgroundTimeDidEnd()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        log.info("Received message from Watch: \(message.keys.joined(separator: ", "))")
        Task { @MainActor in
            self.handleWatchMessage(message, reply: WatchReply(replyHandler))
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        log.info("Received message from Watch (no reply): \(message.keys.joined(separator: ", "))")
        Task { @MainActor in
            self.handleWatchMessage(message, reply: WatchReply(nil))
        }
    }

    // MARK: - Watch actions

    private func handleWatchMessage(_ message: [String: Any], reply: WatchReply) {
        holdBackgroundTime()

        guard let tvManager else {
            log.error("handleWatchMessage: tvManager is nil, cannot process")
            reply.send(errorReply(.tvUnreachable, message: "TV Manager not available"))
            return
        }
        guard let action = message["action"] as? String else {
            log.warning("Watch sent a message with no action")
            reply.send(errorReply(.tvUnreachable, message: "Missing action"))
            return
        }

        log.info("Processing Watch action: '\(action)'")
        switch action {
        case "getDevices":
            reply.send(["devices": tvManager.pairedDevicesPayload()])

        case "getState":
            tvManager.dropStaleSessionIfBackgrounded()
            reply.send(["state": tvManager.status.wirePayload, "phoneInUse": tvManager.isForeground])

        case "connect":
            guard let deviceId = message["deviceId"] as? String,
                  let device = tvManager.pairedDevices.first(where: { $0.id == deviceId }) else {
                log.error("Watch connect: unknown device")
                reply.send(errorReply(.needsPairing, message: "Device not found"))
                return
            }
            Task { @MainActor in
                if let failure = await self.waitForConnection(to: device, on: tvManager) {
                    log.error("Watch connect failed: \(failure.rawValue)")
                    reply.send(self.errorReply(failure))
                } else {
                    reply.send(["status": "connected", "state": tvManager.status.wirePayload])
                }
            }

        case "disconnect":
            tvManager.watchRequestedDisconnect()
            reply.send(["status": "disconnected"])

        case "command":
            guard let name = message["command"] as? String,
                  let command = RemoteCommand(rawValue: name) else {
                log.error("Watch sent an unknown command")
                reply.send(errorReply(.tvUnreachable, message: "Unknown command"))
                return
            }
            relay(command, deviceId: message["deviceId"] as? String, on: tvManager, reply: reply)

        default:
            log.warning("Watch sent unknown action: '\(action)'")
            reply.send(errorReply(.tvUnreachable, message: "Unknown action"))
        }
    }

    private func relay(_ command: RemoteCommand, deviceId: String?, on tvManager: TVManager, reply: WatchReply) {
        let receivedAt = Date()
        let previous = commandChain
        commandChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else {
                reply.send(["status": "error", "failure": ConnectionFailure.tvUnreachable.rawValue])
                return
            }
            await self.perform(command, deviceId: deviceId, receivedAt: receivedAt, on: tvManager, reply: reply)
        }
    }

    private func perform(
        _ command: RemoteCommand,
        deviceId: String?,
        receivedAt: Date,
        on tvManager: TVManager,
        reply: WatchReply
    ) async {
        if let lastRelayFailure, lastRelayFailure.at >= receivedAt {
            reply.send(errorReply(lastRelayFailure.failure))
            return
        }

        // A TV the Watch names but the phone no longer has must not fall through to another TV.
        let named = deviceId.flatMap { id in tvManager.pairedDevices.first { $0.id == id } }
        guard let target = deviceId == nil ? tvManager.activeDevice ?? tvManager.lastDevice : named else {
            log.error("Watch command: no device to send to")
            reply.send(errorReply(.needsPairing, message: "Device not found"))
            return
        }

        // Pressing the remote should just work: bring the session back first.
        if !tvManager.remoteConnection.isSessionFresh || tvManager.activeDevice?.id != target.id {
            log.info("Watch command needs a session, connecting to '\(target.displayName)'")
            if let failure = await waitForConnection(to: target, on: tvManager) {
                lastRelayFailure = (Date(), failure)
                reply.send(errorReply(failure))
                return
            }
        }

        if tvManager.sendCommand(command) {
            reply.send(["status": "ok", "state": tvManager.status.wirePayload])
        } else {
            log.error("Watch command dropped: not connected")
            reply.send(errorReply(tvManager.phase.failure ?? .tvUnreachable))
        }
    }

    /// Nil when connected. Answers within `relayWaitSeconds` even if the attempt is
    /// still going, since the Watch stops waiting. tvState reports how it ends.
    private func waitForConnection(to device: TVDevice, on tvManager: TVManager) async -> ConnectionFailure? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ConnectionFailure?, Never>) in
            let wait = ConnectionWait(continuation)
            let timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(relayWaitSeconds))
                guard !Task.isCancelled else { return }
                wait.finish(.timeout)
            }
            Task { @MainActor in
                var failure: ConnectionFailure?
                do {
                    try await tvManager.connectAndWait(to: device)
                } catch {
                    failure = tvManager.phase.failure ?? (error as? ConnectionError)?.failure ?? .tvUnreachable
                }
                timer.cancel()
                wait.finish(failure)
            }
        }
    }

    private func errorReply(_ failure: ConnectionFailure, message: String? = nil) -> [String: Any] {
        [
            "status": "error",
            "failure": failure.rawValue,
            "message": message ?? failure.message,
        ]
    }
}
