import Foundation
import Network
import Security
import os

nonisolated(unsafe) private let log = Logger(subsystem: "gr.orestislef.TVRemote.watchkitapp", category: "TVConnection")

/// Feature bitmask matching the reference client (no voice/mic):
/// PING|KEY|IME|POWER|VOLUME|APP_LINK = 1|2|4|32|64|512
private let defaultFeatureMask: UInt64 = 615

enum WatchConnectionError: Error, LocalizedError {
    case noIdentity
    case connectionFailed(String)
    case notConnected
    case timeout

    var errorDescription: String? {
        switch self {
        case .noIdentity: return "No TLS certificate on Watch"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .notConnected: return "Not connected to TV"
        case .timeout: return "Connection timed out"
        }
    }
}

@Observable
final class WatchTVConnection {
    var isConnected = false
    var deviceName: String?

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var features: UInt64 = defaultFeatureMask
    private var handshakeDone = false

    func connect(to device: TVDevice) async throws {
        log.info("=== WATCH DIRECT CONNECT === device='\(device.displayName)' host=\(device.host) port=\(device.port)")

        guard let identity = WatchCertificateStore.shared.getIdentity() else {
            log.error("No TLS identity available on Watch")
            throw WatchConnectionError.noIdentity
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

        log.info("Connecting to \(device.host):\(device.port) via TLS from Watch...")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    log.info("TLS connection READY (Watch direct)")
                    cont.resume()
                case .failed(let error):
                    log.error("TLS connection FAILED: \(error.localizedDescription)")
                    self?.isConnected = false
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(throwing: WatchConnectionError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    log.info("TLS connection CANCELLED")
                    self?.isConnected = false
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(throwing: WatchConnectionError.connectionFailed("Cancelled"))
                case .waiting(let error):
                    log.warning("TLS connection WAITING: \(error.localizedDescription)")
                case .preparing:
                    log.debug("TLS connection preparing...")
                default:
                    log.debug("TLS connection state: \(String(describing: state))")
                }
            }
            conn.start(queue: .main)

            // Timeout after 10 seconds
            Task {
                try? await Task.sleep(for: .seconds(10))
                guard !resumed else { return }
                resumed = true
                log.error("Connection timeout (10s)")
                conn.cancel()
                cont.resume(throwing: WatchConnectionError.timeout)
            }
        }

        conn.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                log.error("Watch connection lost: \(error.localizedDescription)")
                self?.isConnected = false
            }
        }

        startReceiving()

        // Handshake: the TV drives the sequence — it sends RemoteConfigure,
        // then RemoteSetActive; the receive callback replies to each. We just
        // poll until the dance completes.
        var started = false
        let handshakeDeadline = Date().addingTimeInterval(8)

        while !started && Date() < handshakeDeadline {
            try await Task.sleep(for: .milliseconds(150))
            started = handshakeDone
        }

        guard started else {
            log.error("Handshake incomplete (timeout)")
            throw WatchConnectionError.timeout
        }

        isConnected = true
        log.info("=== WATCH CONNECTED === Ready to send commands to '\(device.displayName)'")
    }

    func disconnect() {
        log.info("Disconnecting Watch direct connection")
        connection?.cancel()
        connection = nil
        isConnected = false
        deviceName = nil
        receiveBuffer = Data()
    }

    func sendCommand(_ command: RemoteCommand) -> Bool {
        guard isConnected, connection != nil else {
            log.warning("sendCommand(\(command.rawValue)): not connected")
            return false
        }
        log.info("Sending command: \(command.rawValue) (keyCode=\(command.keyCode))")
        let msg = buildKeyInject(keyCode: command.keyCode, direction: 3)
        send(msg)
        return true
    }

    // MARK: - Message Building

    private func buildRemoteConfigureReply() -> Data {
        var deviceInfo = ProtobufEncoder()
        deviceInfo.addVarint(field: 3, value: 1)           // unknown1
        deviceInfo.addString(field: 4, value: "1")         // unknown2
        deviceInfo.addString(field: 5, value: "atvremote") // package_name
        deviceInfo.addString(field: 6, value: "1.0.0")     // app_version

        var configure = ProtobufEncoder()
        configure.addVarint(field: 1, value: features)     // code1 (feature bitmask)
        configure.addMessage(field: 2, encoder: deviceInfo)

        var message = ProtobufEncoder()
        message.addMessage(field: 1, encoder: configure)   // remote_configure = field 1

        return MessageFraming.frame(message.encoded)
    }

    private func buildRemoteSetActiveReply() -> Data {
        var setActive = ProtobufEncoder()
        setActive.addVarint(field: 1, value: features)     // active = feature bitmask

        var message = ProtobufEncoder()
        message.addMessage(field: 2, encoder: setActive)   // remote_set_active = field 2

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
        message.addMessage(field: 9, encoder: ping)        // remote_ping_response = field 9

        return MessageFraming.frame(message.encoded)
    }

    // MARK: - Network I/O

    private func send(_ data: Data) {
        log.debug("Sending \(data.count) bytes")
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                log.error("Send error: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.isConnected = false
                }
            }
        })
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                log.debug("Received \(data.count) bytes")
                self.receiveBuffer.append(data)
                self.processMessages()
            }
            if let error {
                log.error("Receive error: \(error.localizedDescription)")
            }
            if isComplete {
                log.info("Watch connection EOF")
            } else if error == nil {
                self.startReceiving()
            }
        }
    }

    private func processMessages() {
        while let message = MessageFraming.extractMessage(from: &receiveBuffer) {
            log.debug("Processing message: \(message.count) bytes")
            handleMessage(message)
        }
    }

    private func handleMessage(_ data: Data) {
        if let reply = handleHandshakeMessage(data) {
            send(reply)
        }
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
                print("[WATCH] TV features=\(code1) → using \(features)")
                handshakeDone = true
                return buildRemoteConfigureReply()
            case (2, 2): // remote_set_active from TV
                let body = decoder.readLengthDelimited()
                var b = ProtobufDecoder(data: body)
                while let t = b.readTag() { b.skip(wireType: t.wireType) }
                print("[WATCH] TV SetActive → replying active=\(defaultFeatureMask)")
                return buildRemoteSetActiveReply()
            case (8, 2): // remote_ping_request
                let body = decoder.readLengthDelimited()
                var b = ProtobufDecoder(data: body)
                var val: UInt64 = 0
                while let t = b.readTag() {
                    if t.field == 1 && t.wireType == 0 { val = b.readVarint() }
                    else { b.skip(wireType: t.wireType) }
                }
                print("[WATCH] ping \(val) → replying")
                return buildPingResponse(val: val)
            case (3, 2): // remote_error
                let body = decoder.readLengthDelimited()
                var b = ProtobufDecoder(data: body)
                var code: UInt64 = 0
                while let t = b.readTag() {
                    if t.field == 1 && t.wireType == 0 { code = b.readVarint() }
                    else { b.skip(wireType: t.wireType) }
                }
                print("[WATCH] TV ERROR code=\(code)")
                return nil
            default:
                print("[WATCH] msg field \(tag.field)")
                decoder.skip(wireType: tag.wireType)
            }
        }
        return nil
    }
}
