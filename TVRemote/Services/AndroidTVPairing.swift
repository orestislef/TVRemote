import Foundation
import Network
import Security
import CryptoKit
import os

private let log = Logger(subsystem: "gr.orestislef.TVRemote", category: "Pairing")

enum PairingError: Error, LocalizedError {
    case noIdentity
    case connectionFailed(String)
    case pairingRejected
    case invalidResponse
    case timeout
    case serverCertNotAvailable

    var errorDescription: String? {
        switch self {
        case .noIdentity: return "No client certificate available"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .pairingRejected: return "TV rejected the pairing request"
        case .invalidResponse: return "Invalid response from TV"
        case .timeout: return "Connection timed out"
        case .serverCertNotAvailable: return "Could not get server certificate"
        }
    }
}

@Observable
final class AndroidTVPairing {
    var state: PairingState = .idle
    var errorMessage: String?

    enum PairingState: Equatable {
        case idle
        case connecting
        case waitingForCode
        case verifying
        case success
        case failed
    }

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var serverCertificateData: Data?
    private var continuation: CheckedContinuation<Data, Error>?

    func startPairing(device: TVDevice) async throws {
        state = .connecting
        errorMessage = nil
        log.info("=== PAIRING START === device='\(device.displayName)' host=\(device.host) pairingPort=\(device.pairingPort)")

        let identity: SecIdentity
        do {
            identity = try CertificateManager.shared.getOrCreateIdentity()
            log.info("TLS identity obtained")
        } catch {
            log.error("Failed to get TLS identity: \(error.localizedDescription)")
            state = .failed
            errorMessage = error.localizedDescription
            throw PairingError.noIdentity
        }

        // Connect to pairing port via TLS
        let tlsOptions = NWProtocolTLS.Options()

        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            sec_identity_create(identity)!
        )
        log.info("TLS local identity set")

        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { [weak self] metadata, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                if let certChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                   let serverCert = certChain.first {
                    let certData = SecCertificateCopyData(serverCert) as Data
                    let summary = SecCertificateCopySubjectSummary(serverCert) as String? ?? "unknown"
                    log.info("Server certificate captured: subject='\(summary)' size=\(certData.count) bytes")
                    Task { @MainActor in
                        self?.serverCertificateData = certData
                    }
                } else {
                    log.warning("Could not extract server certificate from TLS handshake")
                }
                complete(true)
            },
            .main
        )

        let params = NWParameters(tls: tlsOptions)
        let conn = NWConnection(
            host: NWEndpoint.Host(device.host),
            port: NWEndpoint.Port(rawValue: UInt16(device.pairingPort))!,
            using: params
        )

        self.connection = conn
        log.info("Connecting to \(device.host):\(device.pairingPort) via TLS...")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    log.info("TLS connection READY (pairing port)")
                    cont.resume()
                case .failed(let error):
                    log.error("TLS connection FAILED: \(error.localizedDescription)")
                    cont.resume(throwing: PairingError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    log.info("TLS connection CANCELLED")
                    cont.resume(throwing: PairingError.connectionFailed("Cancelled"))
                case .waiting(let error):
                    log.warning("TLS connection WAITING: \(error.localizedDescription)")
                case .preparing:
                    log.debug("TLS connection preparing...")
                default:
                    log.debug("TLS connection state: \(String(describing: state))")
                }
            }
            conn.start(queue: .main)
        }

        conn.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                log.error("Pairing connection lost: \(error.localizedDescription)")
                Task { @MainActor in
                    self?.state = .failed
                    self?.errorMessage = "Connection lost"
                }
            }
        }

        startReceiving()

        // Step 1: Send PairingRequest
        log.info("Step 1: Sending PairingRequest (serviceName='atvremote', clientName='TVRemote iOS')")
        let requestMsg = buildPairingRequest(serviceName: "atvremote", clientName: "TVRemote iOS")
        send(requestMsg)

        // Step 2: Wait for PairingRequestAck
        log.info("Step 2: Waiting for PairingRequestAck...")
        let ackData = try await waitForMessage()
        let ackOk = parsePairingStatus(ackData)
        log.info("Step 2: PairingRequestAck received, status OK=\(ackOk), raw=\(ackData.map { String(format: "%02X", $0) }.joined())")
        guard ackOk else {
            log.error("Pairing request rejected by TV")
            throw PairingError.pairingRejected
        }

        // Step 3: Send PairingOption
        log.info("Step 3: Sending PairingOption (HEXADECIMAL, symbol_length=6)")
        let optionMsg = buildPairingOption()
        send(optionMsg)

        // Step 4: Wait for PairingConfiguration
        log.info("Step 4: Waiting for PairingConfiguration...")
        let configData = try await waitForMessage()
        log.info("Step 4: PairingConfiguration received, raw=\(configData.map { String(format: "%02X", $0) }.joined())")

        state = .waitingForCode
        log.info("=== WAITING FOR PIN CODE === TV should be showing a code on screen")
    }

    func submitCode(_ code: String) async throws {
        state = .verifying
        log.info("=== SUBMITTING CODE === code='\(code)'")

        guard let serverCertData = serverCertificateData else {
            log.error("No server certificate data available")
            throw PairingError.serverCertNotAvailable
        }
        guard let clientCertData = CertificateManager.shared.getClientCertificateData() else {
            log.error("No client certificate data available")
            throw PairingError.noIdentity
        }

        log.info("Computing pairing secret: clientCert=\(clientCertData.count)B, serverCert=\(serverCertData.count)B, code='\(code)'")
        let secret = computePairingSecret(
            clientCert: clientCertData,
            serverCert: serverCertData,
            code: code
        )
        log.info("Secret computed: \(secret.map { String(format: "%02X", $0) }.joined())")

        // Step 5: Send PairingSecret
        log.info("Step 5: Sending PairingSecret")
        let secretMsg = buildPairingSecret(secret: secret)
        send(secretMsg)

        // Step 6: Wait for PairingSecretAck
        log.info("Step 6: Waiting for PairingSecretAck...")
        let ackData = try await waitForMessage()
        let ackOk = parsePairingStatus(ackData)
        log.info("Step 6: PairingSecretAck received, status OK=\(ackOk), raw=\(ackData.map { String(format: "%02X", $0) }.joined())")

        guard ackOk else {
            log.error("TV rejected the pairing secret (wrong code?)")
            state = .failed
            errorMessage = "TV rejected the code. Make sure you entered it correctly."
            throw PairingError.pairingRejected
        }

        state = .success
        log.info("=== PAIRING SUCCESS ===")
        disconnect()
    }

    func cancel() {
        log.info("Pairing cancelled by user")
        disconnect()
        state = .idle
    }

    private func disconnect() {
        log.info("Disconnecting pairing connection")
        connection?.cancel()
        connection = nil
        receiveBuffer = Data()
    }

    // MARK: - Secret Computation

    private func computePairingSecret(clientCert: Data, serverCert: Data, code: String) -> Data {
        var hashInput = Data()
        hashInput.append(clientCert)
        hashInput.append(contentsOf: [0, 0, 0, 0])
        hashInput.append(serverCert)
        hashInput.append(contentsOf: [0, 0, 0, 0])

        let cleanCode = code.replacingOccurrences(of: " ", with: "").uppercased()
        var codeBytes = Data()
        var i = cleanCode.startIndex
        while i < cleanCode.endIndex {
            let next = cleanCode.index(i, offsetBy: 2, limitedBy: cleanCode.endIndex) ?? cleanCode.endIndex
            if let byte = UInt8(cleanCode[i..<next], radix: 16) {
                codeBytes.append(byte)
            }
            i = next
        }
        log.info("Code '\(cleanCode)' -> \(codeBytes.count) bytes: \(codeBytes.map { String(format: "%02X", $0) }.joined())")
        hashInput.append(codeBytes)

        log.info("Hash input total: \(hashInput.count) bytes")
        let hash = SHA256.hash(data: hashInput)
        return Data(hash)
    }

    // MARK: - Message Building

    private func buildPairingRequest(serviceName: String, clientName: String) -> Data {
        var request = ProtobufEncoder()
        request.addString(field: 1, value: serviceName)
        request.addString(field: 2, value: clientName)

        var message = ProtobufEncoder()
        message.addVarint(field: 1, value: 200)
        message.addVarint(field: 2, value: 2)
        message.addMessage(field: 10, encoder: request)

        let framed = MessageFraming.frame(message.encoded)
        log.debug("PairingRequest built: \(framed.count) bytes")
        return framed
    }

    private func buildPairingOption() -> Data {
        var encoding = ProtobufEncoder()
        encoding.addVarint(field: 1, value: 3)
        encoding.addVarint(field: 2, value: 6)

        var option = ProtobufEncoder()
        option.addVarint(field: 1, value: 1)
        option.addMessage(field: 2, encoder: encoding)

        var message = ProtobufEncoder()
        message.addVarint(field: 1, value: 200)
        message.addVarint(field: 2, value: 2)
        message.addMessage(field: 20, encoder: option)

        let framed = MessageFraming.frame(message.encoded)
        log.debug("PairingOption built: \(framed.count) bytes")
        return framed
    }

    private func buildPairingSecret(secret: Data) -> Data {
        var secretMsg = ProtobufEncoder()
        secretMsg.addBytes(field: 1, value: secret)

        var message = ProtobufEncoder()
        message.addVarint(field: 1, value: 200)
        message.addVarint(field: 2, value: 2)
        message.addMessage(field: 40, encoder: secretMsg)

        let framed = MessageFraming.frame(message.encoded)
        log.debug("PairingSecret built: \(framed.count) bytes")
        return framed
    }

    // MARK: - Message Parsing

    private func parsePairingStatus(_ data: Data) -> Bool {
        var decoder = ProtobufDecoder(data: data)
        while let tag = decoder.readTag() {
            if tag.field == 1 && tag.wireType == 0 {
                let status = decoder.readVarint()
                log.info("Parsed pairing status: \(status) (200=OK)")
                return status == 200
            }
            decoder.skip(wireType: tag.wireType)
        }
        log.warning("No status field found in pairing response")
        return false
    }

    // MARK: - Network I/O

    private func send(_ data: Data) {
        log.debug("Sending \(data.count) bytes: \(data.prefix(32).map { String(format: "%02X", $0) }.joined())...")
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error {
                log.error("Send error: \(error.localizedDescription)")
            } else {
                log.debug("Send completed successfully")
            }
        })
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                log.debug("Received \(data.count) bytes: \(data.prefix(32).map { String(format: "%02X", $0) }.joined())...")
                self.receiveBuffer.append(data)
                if let message = MessageFraming.extractMessage(from: &self.receiveBuffer) {
                    log.info("Complete message extracted: \(message.count) bytes")
                    self.continuation?.resume(returning: message)
                    self.continuation = nil
                }
            }
            if let error {
                log.error("Receive error: \(error.localizedDescription)")
            }
            if isComplete {
                log.info("Connection receive completed (EOF)")
            } else if error == nil {
                self.startReceiving()
            }
        }
    }

    private func waitForMessage() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont

            if let message = MessageFraming.extractMessage(from: &self.receiveBuffer) {
                log.info("Message already buffered: \(message.count) bytes")
                self.continuation = nil
                cont.resume(returning: message)
                return
            }

            Task {
                try await Task.sleep(for: .seconds(30))
                if self.continuation != nil {
                    log.error("Timeout waiting for pairing message (30s)")
                    self.continuation?.resume(throwing: PairingError.timeout)
                    self.continuation = nil
                }
            }
        }
    }
}
