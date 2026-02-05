import Foundation
import Network
import Security
import os

private let log = Logger(subsystem: "gr.orestislef.TVRemote.watchkitapp", category: "TVConnection")

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
    private var configDone = false

    func connect(to device: TVDevice) async throws {
        log.info("=== WATCH DIRECT CONNECT === device='\(device.displayName)' host=\(device.host) port=\(device.port)")

        guard let identity = WatchCertificateStore.shared.getIdentity() else {
            log.error("No TLS identity available on Watch")
            throw WatchConnectionError.noIdentity
        }
        log.info("TLS identity obtained from Watch keychain")

        let tlsOptions = NWProtocolTLS.Options()

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
        self.configDone = false

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

        // Send configuration
        log.info("Sending RemoteConfigure (code1=622, device=AppleWatch/Apple)")
        let configMsg = buildRemoteConfigure()
        send(configMsg)

        // Wait for config response
        try? await Task.sleep(for: .milliseconds(500))

        // Send set active
        log.info("Sending RemoteSetActive (active=622)")
        let activeMsg = buildRemoteSetActive()
        send(activeMsg)

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

    func sendCommand(_ command: RemoteCommand) {
        guard isConnected else {
            log.warning("sendCommand(\(command.rawValue)): not connected")
            return
        }
        log.info("Sending command: \(command.rawValue) (keyCode=\(command.keyCode))")
        let msg = buildKeyInject(keyCode: command.keyCode, direction: 3)
        send(msg)
    }

    // MARK: - Message Building

    private func buildRemoteConfigure() -> Data {
        var deviceInfo = ProtobufEncoder()
        deviceInfo.addString(field: 1, value: "Apple Watch")
        deviceInfo.addString(field: 2, value: "Apple")
        deviceInfo.addVarint(field: 3, value: UInt64(1))
        deviceInfo.addString(field: 4, value: "1.0.0")
        deviceInfo.addString(field: 5, value: "gr.orestislef.TVRemote")

        var configure = ProtobufEncoder()
        configure.addVarint(field: 1, value: UInt64(622))
        configure.addMessage(field: 2, encoder: deviceInfo)

        var message = ProtobufEncoder()
        message.addMessage(field: 7, encoder: configure)

        return MessageFraming.frame(message.encoded)
    }

    private func buildRemoteSetActive() -> Data {
        var setActive = ProtobufEncoder()
        setActive.addVarint(field: 1, value: UInt64(622))

        var message = ProtobufEncoder()
        message.addMessage(field: 8, encoder: setActive)

        return MessageFraming.frame(message.encoded)
    }

    private func buildKeyInject(keyCode: Int32, direction: Int32) -> Data {
        var keyInject = ProtobufEncoder()
        keyInject.addVarint(field: 1, value: UInt64(keyCode))
        keyInject.addVarint(field: 2, value: UInt64(direction))

        var message = ProtobufEncoder()
        message.addMessage(field: 2, encoder: keyInject)

        return MessageFraming.frame(message.encoded)
    }

    private func buildPingResponse(val: UInt64) -> Data {
        var ping = ProtobufEncoder()
        ping.addVarint(field: 1, value: val)

        var message = ProtobufEncoder()
        message.addMessage(field: 11, encoder: ping)

        return MessageFraming.frame(message.encoded)
    }

    // MARK: - Network I/O

    private func send(_ data: Data) {
        log.debug("Sending \(data.count) bytes")
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error {
                log.error("Send error: \(error.localizedDescription)")
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
        var decoder = ProtobufDecoder(data: data)
        while let tag = decoder.readTag() {
            switch tag.field {
            case 7 where tag.wireType == 2:
                log.info("Received RemoteConfigure response")
                decoder.skip(wireType: tag.wireType)
            case 8 where tag.wireType == 2:
                log.info("Received RemoteSetActive response")
                decoder.skip(wireType: tag.wireType)
            case 10 where tag.wireType == 2:
                let pingData = decoder.readLengthDelimited()
                var pingDecoder = ProtobufDecoder(data: pingData)
                var val: UInt64 = 0
                while let ptag = pingDecoder.readTag() {
                    if ptag.field == 1 && ptag.wireType == 0 {
                        val = pingDecoder.readVarint()
                    } else {
                        pingDecoder.skip(wireType: ptag.wireType)
                    }
                }
                log.info("Received Ping (val=\(val)), sending Pong")
                send(buildPingResponse(val: val))
            case 40 where tag.wireType == 2:
                log.info("Received RemoteStart message")
                decoder.skip(wireType: tag.wireType)
            default:
                log.debug("Unknown message field=\(tag.field) wireType=\(tag.wireType)")
                decoder.skip(wireType: tag.wireType)
            }
        }
    }
}
