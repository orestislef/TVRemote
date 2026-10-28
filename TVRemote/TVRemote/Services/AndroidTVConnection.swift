import Foundation
import Network
import Security
import os

nonisolated(unsafe) private let log = Logger(subsystem: "gr.orestislef.TVRemote", category: "Connection")

/// Feature bitmask matching the reference client (no voice/mic):
/// PING|KEY|IME|POWER|VOLUME|APP_LINK = 1|2|4|32|64|512
private let defaultFeatureMask: UInt64 = 615

enum ConnectionError: Error, LocalizedError {
    case noIdentity
    case connectionFailed(String)
    case notConnected
    case timeout

    var errorDescription: String? {
        switch self {
        case .noIdentity: return "No client certificate"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .notConnected: return "Not connected to TV"
        case .timeout: return "Connection timed out"
        }
    }
}

@Observable
final class AndroidTVConnection {
    var isConnected = false
    var deviceName: String?
    var currentApp: String = ""
    var volumeLevel: Int = 0
    var volumeMax: Int = 100
    var volumeMuted = false

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var features: UInt64 = defaultFeatureMask
    private var handshakeDone = false

    func connect(to device: TVDevice) async throws {
        log.info("=== REMOTE CONNECT === device='\(device.displayName)' host=\(device.host) port=\(device.port)")

        // Reuse an existing live session instead of opening a second one —
        // the TV only accepts one remote client at a time.
        if isConnected, connection?.state == .ready {
            log.info("Remote already connected to '\(self.deviceName ?? "?")', reusing")
            print("[CONN] connect() skipped — session already active")
            return
        }
        // Close any stale session first
        if connection != nil {
            log.info("Closing stale remote session")
            connection?.cancel()
            connection = nil
            isConnected = false
            receiveBuffer = Data()
        }

        let identity: SecIdentity
        do {
            identity = try CertificateManager.shared.getOrCreateIdentity()
            log.info("TLS identity obtained for remote connection")
        } catch {
            log.error("Failed to get TLS identity: \(error.localizedDescription)")
            throw ConnectionError.noIdentity
        }

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

        let params = NWParameters(tls: tlsOptions)
        let conn = NWConnection(
            host: NWEndpoint.Host(device.host),
            port: NWEndpoint.Port(rawValue: UInt16(device.port))!,
            using: params
        )

        self.connection = conn
        self.deviceName = device.displayName
        self.features = defaultFeatureMask
        self.handshakeDone = false
        self.receiveBuffer = Data()
        self.currentApp = ""
        self.volumeLevel = 0
        self.volumeMax = 100
        self.volumeMuted = false

        log.info("Connecting to \(device.host):\(device.port) via TLS...")

        // 10s timeout so a stalled .waiting handshake never hangs the UI forever
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            log.info("TLS connection READY (remote port)")
                            print("[CONN] TLS handshake READY on port \(device.port)")
                            cont.resume()
                        case .failed(let error):
                            log.error("TLS connection FAILED: \(error.localizedDescription)")
                            print("[CONN] TLS FAILED: \(error.localizedDescription)")
                            cont.resume(throwing: ConnectionError.connectionFailed(error.localizedDescription))
                        case .cancelled:
                            log.info("TLS connection CANCELLED")
                            print("[CONN] TLS CANCELLED")
                            cont.resume(throwing: ConnectionError.connectionFailed("Cancelled"))
                        case .waiting(let error):
                            log.warning("TLS connection WAITING: \(error.localizedDescription)")
                            print("[CONN] TLS WAITING: \(error.localizedDescription) — cancelling")
                            conn.cancel()
                        case .preparing:
                            log.debug("TLS connection preparing...")
                        default:
                            log.debug("TLS connection state: \(String(describing: state))")
                        }
                    }
                    conn.start(queue: .main)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                conn.cancel()
                throw ConnectionError.timeout
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                log.info("Remote connection lost check")
            case .failed(let error):
                log.error("Remote connection lost: \(error.localizedDescription)")
                print("[CONN] session FAILED: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.isConnected = false
                    self?.connection = nil
                }
            case .cancelled:
                log.info("Remote connection cancelled")
                print("[CONN] session CANCELLED")
                Task { @MainActor [weak self] in
                    self?.isConnected = false
                    self?.connection = nil
                }
            default:
                break
            }
        }

        startReceiving()

        // Handshake: the TV drives the sequence — it sends RemoteConfigure,
        // then RemoteSetActive; the receive callback (processMessages →
        // handleMessage → handleHandshakeMessage) replies to each. We just
        // poll until the dance completes.
        var started = false
        let handshakeDeadline = Date().addingTimeInterval(8)

        while !started && Date() < handshakeDeadline {
            try await Task.sleep(for: .milliseconds(150))
            started = handshakeDone
        }

        guard started else {
            print("[CONN] handshake incomplete (timeout)")
            throw ConnectionError.timeout
        }

        isConnected = true
        print("[CONN] isConnected=true, remote ready")
        log.info("=== REMOTE CONNECTED === Ready to send commands to '\(device.displayName)'")
    }

    private func handleHandshakeMessage(_ payload: Data) -> Data? {
        var decoder = ProtobufDecoder(data: payload)
        while let tag = decoder.readTag() {
            switch (tag.field, tag.wireType) {
            case (1, 2): // remote_configure from TV
                let body = decoder.readLengthDelimited()
                var b = ProtobufDecoder(data: body)
                var code1: UInt64 = 0
                while let t = b.readTag() {
                    if t.field == 1 && t.wireType == 0 { code1 = b.readVarint() }
                    else { b.skip(wireType: t.wireType) }
                }
                features = min(defaultFeatureMask, code1)
                print("[CONN] TV features=\(code1) → using \(features)")
                handshakeDone = true
                return buildRemoteConfigureReply()
            case (2, 2): // remote_set_active from TV
                let body = decoder.readLengthDelimited()
                var b = ProtobufDecoder(data: body)
                while let t = b.readTag() { b.skip(wireType: t.wireType) }
                print("[CONN] TV SetActive → replying active=\(defaultFeatureMask)")
                return buildRemoteSetActiveReply()
            case (8, 2): // ping request
                let body = decoder.readLengthDelimited()
                var b = ProtobufDecoder(data: body)
                var val: UInt64 = 0
                while let t = b.readTag() {
                    if t.field == 1 && t.wireType == 0 { val = b.readVarint() }
                    else { b.skip(wireType: t.wireType) }
                }
                print("[CONN] ping \(val) → replying")
                return buildPingResponse(val: val)
            case (20, 2): // remote_ime_key_inject → current app
                let body = decoder.readLengthDelimited()
                var b = ProtobufDecoder(data: body)
                while let t = b.readTag() {
                    if t.field == 1 && t.wireType == 2 { // app_info
                        var app = ProtobufDecoder(data: b.readLengthDelimited())
                        var label = ""
                        var pkg = ""
                        while let at = app.readTag() {
                            if at.field == 10 && at.wireType == 2 { label = app.readString() }
                            else if at.field == 12 && at.wireType == 2 { pkg = app.readString() }
                            else { app.skip(wireType: at.wireType) }
                        }
                        let reveal = label.isEmpty ? pkg : label
                        if !reveal.isEmpty && reveal != currentApp {
                            currentApp = reveal
                            print("[CONN] current app: \(reveal)")
                        }
                    } else { b.skip(wireType: t.wireType) }
                }
            case (50, 2): // remote_set_volume_level → volume state
                let body = decoder.readLengthDelimited()
                var b = ProtobufDecoder(data: body)
                var level = -1
                var max = -1
                var muted: Bool?
                while let t = b.readTag() {
                    switch (t.field, t.wireType) {
                    case (6, 0): max = Int(b.readVarint())
                    case (7, 0): level = Int(b.readVarint())
                    case (8, 0): muted = b.readVarint() != 0
                    default: b.skip(wireType: t.wireType)
                    }
                }
                if level >= 0 { volumeLevel = level }
                if max >= 0 { volumeMax = max }
                if let muted { volumeMuted = muted }
                print("[CONN] volume=\(volumeLevel)/\(volumeMax) muted=\(volumeMuted)")
            case (3, 2): // remote_error
                let body = decoder.readLengthDelimited()
                var b = ProtobufDecoder(data: body)
                var code: UInt64 = 0
                while let t = b.readTag() {
                    if t.field == 1 && t.wireType == 0 { code = b.readVarint() }
                    else { b.skip(wireType: t.wireType) }
                }
                print("[CONN] TV ERROR code=\(code)")
                return nil
            default:
                print("[CONN] handshake field \(tag.field)")
                decoder.skip(wireType: tag.wireType)
            }
        }
        return nil
    }

    func disconnect() {
        log.info("Disconnecting remote connection")
        connection?.cancel()
        connection = nil
        isConnected = false
        deviceName = nil
        receiveBuffer = Data()
    }

    func sendCommand(_ command: RemoteCommand) {
        guard isConnected else {
            log.warning("sendCommand(\(command.rawValue)): not connected, ignoring")
            print("[CONN] sendCommand(\(command.rawValue)) IGNORED — not connected")
            return
        }
        print("[CONN] sendCommand(\(command.rawValue))")
        log.info("Sending command: \(command.rawValue) (keyCode=\(command.keyCode))")
        let msg = buildKeyInject(keyCode: command.keyCode, direction: 3) // SHORT press
        send(msg)
    }

    // MARK: - Message Building

    private func buildRemoteConfigureReply() -> Data {
        var deviceInfo = ProtobufEncoder()
        deviceInfo.addVarint(field: 3, value: 1)          // unknown1
        deviceInfo.addString(field: 4, value: "1")        // unknown2
        deviceInfo.addString(field: 5, value: "atvremote")// package_name
        deviceInfo.addString(field: 6, value: "1.0.0")    // app_version

        var configure = ProtobufEncoder()
        configure.addVarint(field: 1, value: features)    // code1 (feature bitmask)
        configure.addMessage(field: 2, encoder: deviceInfo)

        var message = ProtobufEncoder()
        message.addMessage(field: 1, encoder: configure)  // remote_configure = field 1

        return MessageFraming.frame(message.encoded)
    }

    private func buildRemoteSetActiveReply() -> Data {
        var setActive = ProtobufEncoder()
        setActive.addVarint(field: 1, value: features)    // active = feature bitmask

        var message = ProtobufEncoder()
        message.addMessage(field: 2, encoder: setActive)  // remote_set_active = field 2

        return MessageFraming.frame(message.encoded)
    }

    private func buildKeyInject(keyCode: Int32, direction: Int32) -> Data {
        var keyInject = ProtobufEncoder()
        keyInject.addVarint(field: 1, value: UInt64(keyCode))   // key_code
        keyInject.addVarint(field: 2, value: UInt64(direction)) // direction (SHORT=3)

        var message = ProtobufEncoder()
        message.addMessage(field: 10, encoder: keyInject) // remote_key_inject = field 10

        return MessageFraming.frame(message.encoded)
    }

    private func buildPingResponse(val: UInt64) -> Data {
        var ping = ProtobufEncoder()
        ping.addVarint(field: 1, value: val)

        var message = ProtobufEncoder()
        message.addMessage(field: 9, encoder: ping)       // remote_ping_response = field 9

        return MessageFraming.frame(message.encoded)
    }

    // MARK: - Network I/O

    private func send(_ data: Data) {
        log.debug("Sending \(data.count) bytes")
        print("[CONN] send \(data.count)B: \(data.prefix(24).map { String(format: "%02X", $0) }.joined())")
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                log.error("Send error: \(error.localizedDescription)")
                print("[CONN] send ERROR: \(error.localizedDescription)")
            } else {
                print("[CONN] send OK (state=\(String(describing: self?.connection?.state)))")
            }
        })
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                print("[CONN] recv \(data.count)B: \(data.prefix(24).map { String(format: "%02X", $0) }.joined())")
                log.debug("Received \(data.count) bytes")
                self.receiveBuffer.append(data)
                self.processMessages()
            }
            if let error {
                log.error("Receive error: \(error.localizedDescription)")
            }
            if isComplete {
                log.info("Remote connection EOF")
            } else if error == nil {
                self.startReceiving()
            }
        }
    }

    private func processMessages() {
        while let message = MessageFraming.extractMessage(from: &receiveBuffer) {
            log.debug("Processing remote message: \(message.count) bytes")
            handleMessage(message)
        }
    }

    private func handleMessage(_ data: Data) {
        if let reply = handleHandshakeMessage(data) {
            send(reply)
        }
    }
}
