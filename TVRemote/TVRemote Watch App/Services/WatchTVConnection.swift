import Foundation
import Network
import Observation
import Security
import os

nonisolated(unsafe) private let log = Logger(subsystem: "gr.orestislef.TVRemote.watchkitapp", category: "TVConnection")

enum ConnectionError: Error, LocalizedError, Equatable {
    case noIdentity
    case cancelled
    case timeout
    /// TLS refused our certificate: the TV no longer knows this client.
    case certificateRejected
    /// The TV closed the socket before the handshake finished.
    case closedBeforeHandshake
    /// An established session ended: EOF, socket error or silence.
    case sessionLost
    case noNetwork
    case localNetworkDenied
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .noIdentity: return "No client certificate"
        case .cancelled: return "Connection cancelled"
        case .timeout: return "Connection timed out"
        case .certificateRejected: return "The TV no longer recognises this device"
        case .closedBeforeHandshake: return "The TV closed the connection"
        case .sessionLost: return "Connection to the TV was lost"
        case .noNetwork: return "No network"
        case .localNetworkDenied: return "Local network access is off"
        case .unreachable(let message): return "Connection failed: \(message)"
        }
    }

    /// What to tell the user once retries have run out.
    var failure: ConnectionFailure {
        switch self {
        case .noIdentity, .certificateRejected, .closedBeforeHandshake: return .needsPairing
        case .timeout, .sessionLost, .cancelled: return .timeout
        case .noNetwork: return .noWiFi
        case .localNetworkDenied: return .localNetworkDenied
        case .unreachable: return .tvUnreachable
        }
    }

    /// Retrying can't help until the user does something.
    var isTerminal: Bool {
        switch self {
        case .noIdentity, .certificateRejected, .localNetworkDenied, .cancelled: return true
        default: return false
        }
    }

    static func from(_ error: NWError, path: NWPath?) -> ConnectionError {
        if path?.unsatisfiedReason == .localNetworkDenied { return .localNetworkDenied }
        switch error {
        case .tls:
            return .certificateRejected
        case .posix(let code):
            switch code {
            case .ENETDOWN, .ENETUNREACH: return .noNetwork
            case .ETIMEDOUT: return .timeout
            default: return .unreachable(error.localizedDescription)
            }
        default:
            return .unreachable(error.localizedDescription)
        }
    }
}

/// A TV that still acks TCP but has stopped talking to us. Sends reset the normal
/// silence clock, so this bounds that case. It sits far above the usual gap because
/// the TV only pings when no command is being sent.
private let inboundSilenceTimeoutSeconds: Double = 60

/// Resumes a continuation exactly once, whichever callback gets there first.
private final class AttemptGate {
    var isDone = false
    var timeoutTask: Task<Void, Never>?
}

@Observable
final class WatchTVConnection {
    private(set) var isConnected = false
    private(set) var connectedDeviceId: String?
    private(set) var deviceName: String?

    // TV-reported state. Kept across a drop so the UI can dim the last value.
    private(set) var volumeLevel: Int?
    private(set) var volumeMax: Int?
    private(set) var volumeMuted = false
    private(set) var isTVOn: Bool?
    private(set) var appLabel = ""
    private(set) var appPackage = ""
    private(set) var lastActivityAt: Date?

    /// An established session ended on its own. Not called after `disconnect()`.
    @ObservationIgnored var onSessionLost: ((ConnectionError) -> Void)?
    /// Any TV-reported value changed.
    @ObservationIgnored var onStateChange: (() -> Void)?
    /// The TV sent remote_error after the handshake. The session stays up.
    @ObservationIgnored var onRemoteError: (() -> Void)?

    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var lastReceivedAt: Date?
    @ObservationIgnored private var receiveBuffer = Data()
    @ObservationIgnored private var features: UInt64 = remoteDefaultFeatureMask
    @ObservationIgnored private var configureSeenAt: Date?
    @ObservationIgnored private var setActiveSeen = false
    @ObservationIgnored private var attemptError: ConnectionError?
    @ObservationIgnored private var failPendingOpen: ((ConnectionError) -> Void)?
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    /// True when the last traffic is recent enough to trust the socket.
    var isSessionFresh: Bool {
        guard isConnected, let lastActivityAt, let lastReceivedAt else { return false }
        let now = Date()
        return now.timeIntervalSince(lastActivityAt) < ReconnectPolicy.silenceTimeoutSeconds
            && now.timeIntervalSince(lastReceivedAt) < inboundSilenceTimeoutSeconds
    }

    func connect(to device: TVDevice) async throws {
        log.info("=== REMOTE CONNECT === device='\(device.displayName)' host=\(device.host) port=\(device.port)")

        // Reuse a live session to this TV instead of opening a second one:
        // the TV only accepts one remote client at a time.
        if isConnected, connectedDeviceId == device.id, connection?.state == .ready {
            log.info("Remote already connected to '\(device.displayName)', reusing")
            return
        }
        teardown()

        guard let identity = WatchCertificateStore.shared.getIdentity() else {
            log.error("No TLS identity available on Watch")
            throw ConnectionError.noIdentity
        }
        log.info("TLS identity obtained from Watch keychain")

        let tlsOptions = NWProtocolTLS.Options()

        // Force TLS 1.2 for compatibility with real Android TV devices
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv12)

        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            sec_identity_create(identity)!
        )

        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, complete in complete(true) },
            .main
        )

        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: device.port)) else {
            throw ConnectionError.unreachable("Invalid port")
        }
        // A TV that loses power sends no FIN, and every press restarts the silence
        // clock. Unacked sends and keepalive probes make TCP itself fail the socket.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 2
        tcpOptions.connectionDropTime = 10

        let conn = NWConnection(
            host: NWEndpoint.Host(device.host),
            port: port,
            using: NWParameters(tls: tlsOptions, tcp: tcpOptions)
        )

        // A different TV must not inherit the previous TV's readings.
        if connectedDeviceId != device.id {
            volumeLevel = nil
            volumeMax = nil
            volumeMuted = false
            appLabel = ""
            appPackage = ""
        }
        connection = conn
        connectedDeviceId = device.id
        deviceName = device.displayName
        features = remoteDefaultFeatureMask
        configureSeenAt = nil
        setActiveSeen = false
        attemptError = nil
        receiveBuffer = Data()
        isTVOn = nil

        log.info("Connecting to \(device.host):\(device.port) via TLS...")

        do {
            try await openSocket(conn)
            try await waitForHandshake(on: conn)
        } catch {
            let connectionError = error as? ConnectionError ?? .cancelled
            log.error("Remote connect failed: \(connectionError.localizedDescription)")
            if connection === conn { teardown() }
            throw connectionError
        }

        isConnected = true
        lastActivityAt = Date()
        lastReceivedAt = Date()
        startWatchdog(on: conn)
        onStateChange?()
        log.info("=== REMOTE CONNECTED === Ready to send commands to '\(device.displayName)'")
    }

    func disconnect() {
        log.info("Disconnecting remote connection")
        teardown()
        connectedDeviceId = nil
        deviceName = nil
        volumeLevel = nil
        volumeMax = nil
        volumeMuted = false
        isTVOn = nil
        appLabel = ""
        appPackage = ""
        onStateChange?()
    }

    /// Returns false when there is no live session to send on.
    @discardableResult
    func sendCommand(_ command: RemoteCommand, direction: KeyDirection = .short) -> Bool {
        guard isConnected, connection != nil else {
            log.warning("sendCommand(\(command.rawValue)): not connected, ignoring")
            return false
        }
        log.info("Sending command: \(command.rawValue) (keyCode=\(command.keyCode))")
        send(RemoteProtocol.keyInject(keyCode: command.keyCode, direction: direction))
        return true
    }

    // MARK: - Socket lifecycle

    private func openSocket(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = AttemptGate()
            let finish: (ConnectionError?) -> Void = { [weak self] error in
                guard !gate.isDone else { return }
                gate.isDone = true
                gate.timeoutTask?.cancel()
                self?.failPendingOpen = nil
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
            failPendingOpen = finish

            // One handler for the whole connection, so a failure right after
            // .ready can't slip through a gap between two handlers.
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    log.info("TLS connection READY (remote port)")
                    finish(nil)
                case .waiting(let error):
                    // Fail fast with the reason. Retries are the caller's job.
                    log.warning("TLS connection WAITING: \(error.localizedDescription)")
                    let mapped = ConnectionError.from(error, path: conn.currentPath)
                    if gate.isDone {
                        Task { @MainActor in self?.sessionEnded(conn, error: mapped) }
                    } else {
                        finish(mapped)
                    }
                case .failed(let error):
                    log.error("TLS connection FAILED: \(error.localizedDescription)")
                    let mapped = ConnectionError.from(error, path: conn.currentPath)
                    if gate.isDone {
                        Task { @MainActor in self?.sessionEnded(conn, error: mapped) }
                    } else {
                        finish(mapped)
                    }
                case .cancelled:
                    log.info("TLS connection CANCELLED")
                    if gate.isDone {
                        Task { @MainActor in self?.sessionEnded(conn, error: .sessionLost) }
                    } else {
                        finish(.cancelled)
                    }
                default:
                    break
                }
            }

            gate.timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                log.error("Connection timeout (10s)")
                finish(.timeout)
            }
            conn.start(queue: .main)
        }
    }

    /// The TV drives the sequence: it sends RemoteConfigure, then RemoteSetActive,
    /// and the receive callback replies to each. Done once SetActive arrives, or
    /// a moment after Configure in case a TV skips SetActive.
    private func waitForHandshake(on conn: NWConnection) async throws {
        startReceiving(on: conn)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            guard connection === conn else { throw ConnectionError.cancelled }
            if let attemptError { throw attemptError }
            if setActiveSeen { return }
            if let configureSeenAt, Date().timeIntervalSince(configureSeenAt) > 2 { return }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                throw ConnectionError.cancelled
            }
        }
        throw configureSeenAt == nil ? ConnectionError.timeout : ConnectionError.sessionLost
    }

    private func startWatchdog(on conn: NWConnection) {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self else { return }
                guard self.connection === conn else { return }
                if !self.isSessionFresh {
                    log.error("Session went silent, treating it as dead")
                    self.sessionEnded(conn, error: .sessionLost)
                    return
                }
            }
        }
    }

    /// Ends the current socket silently. Old callbacks are dropped by the
    /// `connection === conn` checks.
    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        let conn = connection
        connection = nil
        isConnected = false
        receiveBuffer = Data()
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        failPendingOpen?(.cancelled)
        failPendingOpen = nil
    }

    /// The socket for `conn` is gone. Stale callbacks from an older socket do nothing.
    private func sessionEnded(_ conn: NWConnection, error: ConnectionError) {
        guard connection === conn else { return }
        guard isConnected else {
            // Still handshaking: let waitForHandshake report it.
            attemptError = attemptError ?? error
            return
        }
        log.error("Remote session lost: \(error.localizedDescription)")
        teardown()
        onSessionLost?(error)
    }

    // MARK: - Network I/O

    private func send(_ data: Data) {
        guard let conn = connection else { return }
        log.debug("Sending \(data.count) bytes")
        lastActivityAt = Date()
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            log.error("Send error: \(error.localizedDescription)")
            Task { @MainActor [weak self] in
                self?.sessionEnded(conn, error: ConnectionError.from(error, path: conn.currentPath))
            }
        })
    }

    private func startReceiving(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === conn else { return }
            if let data, !data.isEmpty {
                log.debug("Received \(data.count) bytes")
                self.lastActivityAt = Date()
                self.lastReceivedAt = Date()
                self.receiveBuffer.append(data)
                self.processMessages(on: conn)
            }
            guard self.connection === conn else { return }
            if isComplete {
                log.info("Remote connection EOF")
                self.sessionEnded(conn, error: self.isConnected ? .sessionLost : .closedBeforeHandshake)
            } else if let error {
                log.error("Receive error: \(error.localizedDescription)")
                self.sessionEnded(conn, error: ConnectionError.from(error, path: conn.currentPath))
            } else {
                self.startReceiving(on: conn)
            }
        }
    }

    private func processMessages(on conn: NWConnection) {
        while true {
            switch MessageFraming.nextFrame(from: &receiveBuffer) {
            case .message(let message):
                for event in RemoteProtocol.decode(message) {
                    handle(event)
                }
            case .incomplete:
                return
            case .corrupt:
                log.error("Stream lost sync, ending the session")
                sessionEnded(conn, error: .sessionLost)
                return
            }
        }
    }

    private func handle(_ event: RemoteEvent) {
        switch event {
        case .configure(let code):
            features = min(remoteDefaultFeatureMask, code)
            log.info("TV features=\(code), using \(self.features)")
            configureSeenAt = configureSeenAt ?? Date()
            send(RemoteProtocol.configureReply(features: features))
        case .setActive:
            setActiveSeen = true
            send(RemoteProtocol.setActiveReply(features: features))
        case .ping(let value):
            send(RemoteProtocol.pingResponse(value: value))
        case .tvPower(let isOn):
            isTVOn = isOn
            onStateChange?()
        case .volume(let level, let max, let muted):
            volumeLevel = level
            if let max { volumeMax = max }
            volumeMuted = muted
            onStateChange?()
        case .app(let label, let package):
            appLabel = label
            appPackage = package
            onStateChange?()
        case .error(let code):
            log.error("TV sent remote_error code=\(code)")
            if isConnected {
                onRemoteError?()
            } else {
                attemptError = attemptError ?? .closedBeforeHandshake
            }
        }
    }
}
