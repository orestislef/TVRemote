import Foundation
import Network
import Security
import CryptoKit
import Observation
import os

nonisolated(unsafe) private let log = Logger(subsystem: "gr.orestislef.TVRemote", category: "Pairing")

// Import required types from other files
// Note: These should be available in the same target

// MARK: - Constants
private let pairingTimeout: TimeInterval = 30.0
private let maxRetries = 2

enum PairingError: Error, LocalizedError {
    case noIdentity
    case connectionFailed(String)
    case pairingRejected
    case invalidResponse
    case timeout
    case serverCertNotAvailable
    case secretMismatch

    var errorDescription: String? {
        switch self {
        case .noIdentity: return "No client certificate available"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .pairingRejected: return "TV rejected the pairing request"
        case .invalidResponse: return "Invalid response from TV"
        case .timeout: return "Connection timed out"
        case .serverCertNotAvailable: return "Could not get server certificate"
        case .secretMismatch: return "Secret verification failed"
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
        // If a pairing session already reached the PIN stage and is alive, reuse it
        if state == .waitingForCode, connection?.state == .ready {
            print("[PAIR] Existing pairing session still waiting for PIN — reusing it")
            return
        }

        // Always close any stale TLS session first — the TV only allows ONE
        // pairing session at a time and silently ignores requests otherwise.
        if connection != nil {
            print("[PAIR] Cleaning up stale pairing session")
            continuation?.resume(throwing: PairingError.connectionFailed("Stale session"))
            continuation = nil
            disconnect()
            try? await Task.sleep(for: .seconds(1))
        }

        // Try pairing with retries for better reliability
        for attempt in 1...maxRetries {
            if attempt > 1 {
                log.info("Pairing attempt \(attempt) of \(maxRetries)")
                // Clean up any previous session before retry
                if connection != nil {
                    log.info("Cleaning up previous pairing connection before retry")
                    continuation?.resume(throwing: PairingError.connectionFailed("Retry"))
                    continuation = nil
                    disconnect()
                }
                // Small delay before retry
                try? await Task.sleep(for: .seconds(1))
            }
            
            serverCertificateData = nil
            
            state = .connecting
            errorMessage = nil
            log.info("=== PAIRING START (attempt \(attempt)/\(maxRetries)) === device='\(device.displayName)' host=\(device.host) pairingPort=\(device.pairingPort)")
            print("[PAIR] START attempt \(attempt) host=\(device.host) port=\(device.pairingPort)")
            log.info("Network interface check: attempting connection to \(device.host):\(device.pairingPort)")
            
            do {
                let identity = try CertificateManager.shared.getOrCreateIdentity()
                log.info("TLS identity obtained successfully")

                // Connect to pairing port via TLS
                let tlsOptions = NWProtocolTLS.Options()
                sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
                sec_protocol_options_set_max_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
                sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, sec_identity_create(identity)!)
                log.info("TLS local identity set (forced TLS 1.2)")
                print("[PAIR] TLS identity set (forced TLS 1.2)")

                // Disable certificate verification (like Python library does)
                sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { [weak self] metadata, trust, complete in
                    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                    if let certChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                       let serverCert = certChain.first {
                        let certData = SecCertificateCopyData(serverCert) as Data
                        let summary = SecCertificateCopySubjectSummary(serverCert) as String? ?? "unknown"
                        log.info("Server certificate captured: subject='\(summary)' size=\(certData.count) bytes")
                        Task { @MainActor [weak self] in
                            self?.serverCertificateData = certData
                        }
                    } else {
                        log.warning("Could not extract server certificate from TLS handshake")
                    }
                    // Accept any certificate (like Python library's CERT_NONE)
                    complete(true)
                }, .main)

                let params = NWParameters(tls: tlsOptions)
                // Enable peer-to-peer and local network for link-local addresses
                params.includePeerToPeer = true
                
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
                            print("[PAIR] TLS handshake READY")
                            cont.resume()
                        case .failed(let error):
                            log.error("TLS connection FAILED: \(error.localizedDescription)")
                            print("[PAIR] TLS connection FAILED: \(error.localizedDescription)")
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
                    switch state {
                    case .failed(let error):
                        log.error("Pairing connection lost: \(error.localizedDescription)")
                        Task { @MainActor [weak self] in
                            self?.continuation?.resume(throwing: PairingError.connectionFailed(error.localizedDescription))
                            self?.continuation = nil
                            self?.state = .failed
                            self?.errorMessage = "Connection lost"
                        }
                    case .cancelled:
                        log.info("Pairing connection cancelled")
                        Task { @MainActor [weak self] in
                            self?.continuation?.resume(throwing: PairingError.connectionFailed("Cancelled"))
                            self?.continuation = nil
                        }
                    default:
                        break
                    }
                }

                startReceiving()

                // Step 1: Send PairingRequest
                log.info("Step 1: Sending PairingRequest (serviceName='atvremote', clientName='TVRemote iOS')")
                let requestMsg = buildPairingRequest(serviceName: "atvremote", clientName: "TVRemote iOS")
                print("[PAIR] Sending PairingRequest...")
                send(requestMsg)

                // Step 2: Wait for PairingRequestAck
                log.info("Step 2: Waiting for PairingRequestAck...")
                let ackData = try await waitForMessage()
                let ackStatus = parsePairingStatus(ackData)
                print("[PAIR] PairingRequestAck received: status=\(ackStatus) raw=\(ackData.map { String(format: "%02X", $0) }.joined())")
                guard ackStatus == 200 else {
                    log.error("Pairing request rejected by TV (status=\(ackStatus))")
                    throw PairingError.pairingRejected
                }

                // Step 3: Send PairingOption (input encodings = HEXADECIMAL len 6, preferred role INPUT)
                log.info("Step 3: Sending PairingOption (HEXADECIMAL, symbol_length=6)")
                print("[PAIR] Sending PairingOption...")
                let optionMsg = buildPairingOption()
                send(optionMsg)

                // Step 4: Wait for server's PairingOption (field 20)
                log.info("Step 4: Waiting for server PairingOption...")
                let serverOptionsData = try await waitForMessage()
                let serverOptionsStatus = parsePairingStatus(serverOptionsData)
                print("[PAIR] Server PairingOption received: status=\(serverOptionsStatus) raw=\(serverOptionsData.map { String(format: "%02X", $0) }.joined())")
                guard serverOptionsStatus == 200 else {
                    throw PairingError.pairingRejected
                }

                // Step 5: Send PairingConfiguration (encoding=HEXADECIMAL, client_role=INPUT)
                log.info("Step 5: Sending PairingConfiguration...")
                print("[PAIR] Sending PairingConfiguration...")
                let configMsg = buildPairingConfiguration()
                send(configMsg)

                // Step 6: Wait for configuration_ack — the TV shows the PIN after this
                log.info("Step 6: Waiting for configuration_ack...")
                let configAckData = try await waitForMessage()
                let configAckStatus = parsePairingStatus(configAckData)
                print("[PAIR] ConfigurationAck received: status=\(configAckStatus) raw=\(configAckData.map { String(format: "%02X", $0) }.joined())")
                guard configAckStatus == 200 else {
                    print("[PAIR] Configuration rejected by TV (status=\(configAckStatus))")
                    throw PairingError.pairingRejected
                }

                state = .waitingForCode
                print("[PAIR] === WAITING FOR PIN === TV should show a 6-digit code now")
                return // Success, exit the retry loop
            } catch {
                // If this was the last attempt, re-throw the error
                if attempt == maxRetries {
                    log.error("All pairing attempts failed. Last error: \(error)")
                    state = .failed
                    errorMessage = error.localizedDescription
                    throw error
                }
                // Otherwise continue to next attempt
                log.warning("Pairing attempt \(attempt) failed: \(error.localizedDescription). Retrying...")
                continue
            }
        }
    }

    func submitCode(_ code: String) async throws {
        state = .verifying
        log.info("=== SUBMITTING CODE === code='\(code)'")

        // Validate hex code
        let cleanCode = code.replacingOccurrences(of: " ", with: "").uppercased()
        let validHex = cleanCode.allSatisfy { "0123456789ABCDEF".contains($0) }
        guard validHex && cleanCode.count >= 2 && cleanCode.count % 2 == 0 else {
            log.error("Invalid hex code: '\(code)' — must be hex characters (0-9, A-F), even length, at least 2 chars")
            throw PairingError.invalidResponse
        }

        guard let serverCertData = serverCertificateData else {
            log.error("No server certificate data available")
            throw PairingError.serverCertNotAvailable
        }
        guard let clientCertData = CertificateManager.shared.getClientCertificateData() else {
            log.error("No client certificate data available")
            throw PairingError.noIdentity
        }

        log.info("Computing pairing secret: clientCert=\(clientCertData.count)B, serverCert=\(serverCertData.count)B, code='\(cleanCode)'")
        let secret = try computePairingSecret(
            clientCert: clientCertData,
            serverCert: serverCertData,
            code: cleanCode
        )
        log.info("Secret computed: \(secret.map { String(format: "%02X", $0) }.joined())")

        // Step 5: Send PairingSecret
        log.info("Step 5: Sending PairingSecret")
        let secretMsg = buildPairingSecret(secret: secret)
        send(secretMsg)

        // Step 6: Wait for PairingSecretAck
        log.info("Step 6: Waiting for PairingSecretAck...")
                let ackData = try await waitForMessage()
                let ackStatus = parsePairingStatus(ackData)
                print("[PAIR] PairingSecretAck status=\(ackStatus) raw=\(ackData.map { String(format: "%02X", $0) }.joined())")

        guard ackStatus == 200 else {
            log.error("TV rejected the pairing secret (wrong code?)")
            throw PairingError.pairingRejected
        }

        state = .success
        log.info("=== PAIRING SUCCESS ===")
        disconnect()
    }
    
    func cancel() {
        log.info("Pairing cancelled by user")
        continuation?.resume(throwing: PairingError.connectionFailed("Cancelled"))
        continuation = nil
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

    private func computePairingSecret(clientCert: Data, serverCert: Data, code: String) throws -> Data {
        // Extract RSA public key modulus & exponent from both certificates
        guard let clientKey = extractPublicKey(from: clientCert),
              let clientPKCS1 = exportPKCS1(clientKey),
              let (clientMod, clientExp) = parseRSAPublicKey(clientPKCS1) else {
            log.error("Failed to extract client public key components")
            throw PairingError.noIdentity
        }
        let clientModHex = clientMod.map { String(format: "%02X", $0) }.joined()
        let clientExpHex = clientExp.map { String(format: "%02X", $0) }.joined()
        log.info("Client key: modulus=\(clientMod.count)B (\(clientModHex.prefix(32))...) exponent=\(clientExp.count)B (\(clientExpHex))")
        
        guard let serverKey = extractPublicKey(from: serverCert),
              let serverPKCS1 = exportPKCS1(serverKey),
              let (serverMod, serverExp) = parseRSAPublicKey(serverPKCS1) else {
            log.error("Failed to extract server public key components")
            throw PairingError.serverCertNotAvailable
        }
        let serverModHex = serverMod.map { String(format: "%02X", $0) }.joined()
        let serverExpHex = serverExp.map { String(format: "%02X", $0) }.joined()
        log.info("Server key: modulus=\(serverMod.count)B (\(serverModHex.prefix(32))...) exponent=\(serverExp.count)B (\(serverExpHex))")

        // Parse the hex code into bytes
        let cleanCode = code.replacingOccurrences(of: " ", with: "").uppercased()
        let codeBytes = hexToBytes(cleanCode)
        log.info("Code '\(cleanCode)' -> \(codeBytes.count) bytes: \(codeBytes.map { String(format: "%02X", $0) }.joined())")

        // Matches the reference androidtvremote2 implementation:
        //   hash = SHA256(clientModulus + clientExponent + serverModulus + serverExponent + code[1..])
        // (the code hex string's first 2 chars are skipped, per python's pairing_code[2:])
        guard codeBytes.count >= 2 else {
            log.error("Code too short: '\(cleanCode)'")
            throw PairingError.invalidResponse
        }
        var hashInput = Data()
        hashInput.append(clientMod)
        hashInput.append(clientExp)
        hashInput.append(serverMod)
        hashInput.append(serverExp)
        hashInput.append(codeBytes.dropFirst())
        log.info("Hash input total: \(hashInput.count) bytes")

        let hash = SHA256.hash(data: hashInput)
        let secret = Data(hash)

        // Verify check byte: hash[0] must match code[0]
        if !codeBytes.isEmpty && secret[0] != codeBytes[0] {
            log.warning("Secret check byte mismatch: hash[0]=\(String(format: "%02X", secret[0])) code[0]=\(String(format: "%02X", codeBytes[0]))")
            throw PairingError.secretMismatch
        }

        return secret
    }

    private func extractPublicKey(from certDER: Data) -> SecKey? {
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else { return nil }
        return SecCertificateCopyKey(cert)
    }

    private func exportPKCS1(_ key: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        return SecKeyCopyExternalRepresentation(key, &error) as Data?
    }

    /// Parse PKCS#1 RSAPublicKey DER to extract modulus and exponent bytes.
    /// Strips the leading zero byte from modulus (DER sign padding).
    private func parseRSAPublicKey(_ data: Data) -> (modulus: Data, exponent: Data)? {
        var offset = data.startIndex

        // SEQUENCE tag
        guard offset < data.endIndex, data[offset] == 0x30 else { return nil }
        offset += 1

        // SEQUENCE length
        offset = skipDERLength(data, at: offset)

        // First INTEGER: modulus
        guard offset < data.endIndex, data[offset] == 0x02 else { return nil }
        offset += 1
        let modLen = readDERLength(data, at: &offset)
        guard offset + modLen <= data.endIndex else { return nil }
        var modulus = Data(data[offset..<offset + modLen])
        offset += modLen

        // Strip leading zero byte (DER sign padding)
        while modulus.count > 1 && modulus[modulus.startIndex] == 0x00 {
            modulus = modulus.dropFirst()
        }

        // Second INTEGER: exponent
        guard offset < data.endIndex, data[offset] == 0x02 else { return nil }
        offset += 1
        let expLen = readDERLength(data, at: &offset)
        guard offset + expLen <= data.endIndex else { return nil }
        let exponent = Data(data[offset..<offset + expLen])

        return (modulus, exponent)
    }

    private func readDERLength(_ data: Data, at offset: inout Data.Index) -> Int {
        guard offset < data.endIndex else { return 0 }
        let first = data[offset]
        offset += 1
        if first < 0x80 {
            return Int(first)
        }
        let numBytes = Int(first & 0x7F)
        var length = 0
        for _ in 0..<numBytes {
            guard offset < data.endIndex else { return 0 }
            length = (length << 8) | Int(data[offset])
            offset += 1
        }
        return length
    }

    private func skipDERLength(_ data: Data, at offset: Data.Index) -> Data.Index {
        var off = offset
        _ = readDERLength(data, at: &off)
        return off
    }

    private func hexToBytes(_ hex: String) -> Data {
        var data = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[i..<next], radix: 16) {
                data.append(byte)
            }
            i = next
        }
        return data
    }

    // MARK: - Message Building

    private func buildPairingRequest(serviceName: String, clientName: String) -> Data {
        var request = ProtobufEncoder()
        request.addString(field: 1, value: serviceName)
        request.addString(field: 2, value: clientName)

        var message = ProtobufEncoder()
        message.addVarint(field: 1, value: 2)    // protocol_version = 2
        message.addVarint(field: 2, value: 200)  // status = STATUS_OK
        message.addMessage(field: 10, encoder: request)

        let framed = MessageFraming.frame(message.encoded)
        log.debug("PairingRequest built: \(framed.count) bytes")
        return framed
    }

    private func buildPairingOption() -> Data {
        // Matches the reference client: only input_encodings + preferred_role
        var encoding = ProtobufEncoder()
        encoding.addVarint(field: 1, value: 3)  // ENCODING_TYPE_HEXADECIMAL
        encoding.addVarint(field: 2, value: 6)  // symbol_length

        var option = ProtobufEncoder()
        option.addMessage(field: 1, encoder: encoding)  // input_encodings
        option.addVarint(field: 3, value: 1)            // preferred_role = ROLE_TYPE_INPUT

        var message = ProtobufEncoder()
        message.addVarint(field: 1, value: 2)    // protocol_version = 2
        message.addVarint(field: 2, value: 200)  // status = STATUS_OK
        message.addMessage(field: 20, encoder: option)

        let framed = MessageFraming.frame(message.encoded)
        log.debug("PairingOption built: \(framed.count) bytes")
        return framed
    }

    private func buildPairingConfiguration() -> Data {
        var encoding = ProtobufEncoder()
        encoding.addVarint(field: 1, value: 3)  // ENCODING_TYPE_HEXADECIMAL
        encoding.addVarint(field: 2, value: 6)  // symbol_length

        var config = ProtobufEncoder()
        config.addMessage(field: 1, encoder: encoding)  // encoding
        config.addVarint(field: 2, value: 1)            // client_role = ROLE_TYPE_INPUT

        var message = ProtobufEncoder()
        message.addVarint(field: 1, value: 2)    // protocol_version = 2
        message.addVarint(field: 2, value: 200)  // status = STATUS_OK
        message.addMessage(field: 30, encoder: config)

        let framed = MessageFraming.frame(message.encoded)
        log.debug("PairingConfiguration built: \(framed.count) bytes")
        return framed
    }

    private func buildPairingSecret(secret: Data) -> Data {
        var secretMsg = ProtobufEncoder()
        secretMsg.addBytes(field: 1, value: secret)

        var message = ProtobufEncoder()
        message.addVarint(field: 1, value: 2)    // protocol_version = 2
        message.addVarint(field: 2, value: 200)  // status = STATUS_OK
        message.addMessage(field: 40, encoder: secretMsg)

        let framed = MessageFraming.frame(message.encoded)
        log.debug("PairingSecret built: \(framed.count) bytes")
        return framed
    }

    // MARK: - Message Parsing

    /// Parse the status field (field 2) from a PairingMessage response.
    private func parsePairingStatus(_ data: Data) -> UInt64 {
        var decoder = ProtobufDecoder(data: data)
        var status: UInt64 = 0
        while let tag = decoder.readTag() {
            if tag.field == 2 && tag.wireType == 0 {
                status = decoder.readVarint()
                log.info("Parsed pairing status: \(status) (200=OK, 400=ERROR)")
            } else {
                decoder.skip(wireType: tag.wireType)
            }
        }
        return status
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
        guard connection != nil else {
            log.error("waitForMessage called but no connection")
            throw PairingError.connectionFailed("Not connected")
        }
    
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
    
            if let message = MessageFraming.extractMessage(from: &self.receiveBuffer) {
                log.info("Message already buffered: \(message.count) bytes")
                self.continuation = nil
                cont.resume(returning: message)
                return
            }
    
            Task { [weak self] in
                try await Task.sleep(for: .seconds(pairingTimeout))
                if let self, self.continuation != nil {
                    log.error("Timeout waiting for pairing message (\(pairingTimeout)s)")
                    self.continuation?.resume(throwing: PairingError.timeout)
                    self.continuation = nil
                }
            }
        }
    }
}
