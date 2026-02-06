import Foundation
import Security
import CryptoKit
import os

private let log = Logger(subsystem: "gr.orestislef.TVRemote", category: "Certificate")

enum CertificateError: Error {
    case keyGenerationFailed(String)
    case signingFailed
    case certCreationFailed
    case identityNotFound
    case keychainError(OSStatus)
}

final class CertificateManager {
    static let shared = CertificateManager()
    private let keyTag = "gr.orestislef.TVRemote.clientkey"
    private let certLabel = "TVRemote Client"
    private static let certVersion = 3
    private static let certVersionKey = "TVRemote_certVersion"

    private init() {
        migrateIfNeeded()
    }

    /// Delete malformed certificates from previous versions.
    private func migrateIfNeeded() {
        let current = UserDefaults.standard.integer(forKey: Self.certVersionKey)
        if current < Self.certVersion {
            log.info("Certificate migration v\(current) → v\(Self.certVersion), cleaning up old artifacts...")
            deleteExistingKey()
            deleteExistingCert()
            UserDefaults.standard.set(Self.certVersion, forKey: Self.certVersionKey)
            log.info("Certificate migration complete, identity will regenerate on next use")
        }
    }

    // MARK: - Public API

    func getOrCreateIdentity() throws -> SecIdentity {
        log.info("Getting or creating TLS identity...")

        if let identity = findIdentity() {
            log.info("Found existing identity in Keychain")
            return identity
        }

        log.info("No existing identity found, creating new one...")

        // Clean up any old artifacts
        deleteExistingKey()
        deleteExistingCert()

        let privateKey = try generateKeyPair()
        log.info("RSA 2048 key pair generated")

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            log.error("Failed to extract public key from private key")
            throw CertificateError.keyGenerationFailed("Cannot extract public key")
        }

        let certData = try buildSelfSignedCertificate(publicKey: publicKey, privateKey: privateKey)
        log.info("Self-signed certificate built (\(certData.count) bytes)")

        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            log.error("SecCertificateCreateWithData failed - DER encoding may be invalid")
            throw CertificateError.certCreationFailed
        }

        let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "unknown"
        log.info("Certificate created: subject='\(summary)'")

        try addCertificateToKeychain(certificate)
        log.info("Certificate stored in Keychain")

        guard let identity = findIdentity() else {
            log.error("Identity not found after storing key + cert - Keychain pairing failed")
            throw CertificateError.identityNotFound
        }

        log.info("TLS identity ready")
        return identity
    }

    func getClientCertificateData() -> Data? {
        guard let identity = findIdentity() else {
            log.warning("getClientCertificateData: no identity found")
            return nil
        }
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let cert else {
            log.warning("getClientCertificateData: SecIdentityCopyCertificate failed")
            return nil
        }
        let data = SecCertificateCopyData(cert) as Data
        log.info("Client certificate data: \(data.count) bytes")
        return data
    }

    /// Export the private key raw bytes (PKCS1) for transferring to Watch.
    func getPrivateKeyData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            log.warning("getPrivateKeyData: key not found (OSStatus=\(status))")
            return nil
        }
        let key = item as! SecKey
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            log.error("getPrivateKeyData: export failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            return nil
        }
        log.info("Private key exported: \(data.count) bytes (PKCS1)")
        return data
    }

    // MARK: - Keychain Operations

    private func generateKeyPair() throws -> SecKey {
        log.info("Generating RSA 2048 key pair...")
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ] as [String: Any],
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "Unknown"
            log.error("Key generation failed: \(desc)")
            throw CertificateError.keyGenerationFailed(desc)
        }
        log.info("Key pair generated and stored in Keychain with tag '\(self.keyTag)'")
        return key
    }

    private func addCertificateToKeychain(_ certificate: SecCertificate) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certLabel,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            log.info("Certificate added to Keychain (label: '\(self.certLabel)')")
        } else if status == errSecDuplicateItem {
            log.info("Certificate already in Keychain (duplicate)")
        } else {
            log.error("SecItemAdd failed: OSStatus=\(status)")
            throw CertificateError.keychainError(status)
        }
    }

    private func findIdentity() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            log.debug("findIdentity: found (OSStatus=\(status))")
            return (item as! SecIdentity)
        } else {
            log.debug("findIdentity: not found (OSStatus=\(status))")
            return nil
        }
    }

    private func deleteExistingKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
        ]
        let status = SecItemDelete(query as CFDictionary)
        log.debug("deleteExistingKey: OSStatus=\(status)")
    }

    private func deleteExistingCert() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel,
        ]
        let status = SecItemDelete(query as CFDictionary)
        log.debug("deleteExistingCert: OSStatus=\(status)")
    }

    // MARK: - Self-Signed Certificate Builder (DER/ASN.1)

    private func buildSelfSignedCertificate(publicKey: SecKey, privateKey: SecKey) throws -> Data {
        guard let pubKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw CertificateError.keyGenerationFailed("Cannot export public key")
        }
        log.info("Public key exported: \(pubKeyData.count) bytes (PKCS1)")

        let tbs = buildTBSCertificate(publicKeyPKCS1: pubKeyData)
        log.info("TBSCertificate built: \(tbs.count) bytes")

        let signature = try signData(tbs, with: privateKey)
        log.info("TBSCertificate signed: \(signature.count) bytes")

        var cert = Data()
        cert.append(tbs)
        cert.append(sha256WithRSAAlgorithm())
        cert.append(derBitString(signature))
        let fullCert = derSequence(cert)
        log.info("Full certificate DER: \(fullCert.count) bytes")
        return fullCert
    }

    private func buildTBSCertificate(publicKeyPKCS1: Data) -> Data {
        var tbs = Data()
        // Version: v3 (needed for extensions)
        tbs.append(derExplicit(tag: 0, derInteger(Data([2]))))

        var serial = Data(count: 8)
        _ = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        serial[0] &= 0x7F
        tbs.append(derInteger(serial))
        tbs.append(sha256WithRSAAlgorithm())
        tbs.append(buildName("atvremote"))
        tbs.append(buildValidity())
        tbs.append(buildName("atvremote"))
        tbs.append(buildSubjectPublicKeyInfo(publicKeyPKCS1))
        // X.509v3 extensions (explicit tag [3])
        tbs.append(derExplicit(tag: 3, derSequence(buildExtensions())))
        return derSequence(tbs)
    }

    private func buildExtensions() -> Data {
        var extensions = Data()
        // Basic Constraints: critical, CA=TRUE
        // OID 2.5.29.19 = 55 1D 13
        var basicConstraints = Data()
        basicConstraints.append(derOID([0x55, 0x1D, 0x13]))
        basicConstraints.append(derTag(0x01, Data([0xFF]))) // critical = TRUE
        // extnValue: OCTET STRING wrapping SEQUENCE { BOOLEAN TRUE (cA) }
        basicConstraints.append(derTag(0x04, derSequence(derTag(0x01, Data([0xFF])))))
        extensions.append(derSequence(basicConstraints))
        return extensions
    }

    private func sha256WithRSAAlgorithm() -> Data {
        var inner = Data()
        inner.append(derOID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]))
        inner.append(derNull())
        return derSequence(inner)
    }

    private func buildName(_ cn: String) -> Data {
        var atv = Data()
        atv.append(derOID([0x55, 0x04, 0x03]))
        atv.append(derUTF8String(cn))
        return derSequence(derSet(derSequence(atv)))
    }

    private func buildValidity() -> Data {
        let now = Date()
        let tenYears = now.addingTimeInterval(10 * 365.25 * 24 * 3600)
        var validity = Data()
        validity.append(derUTCTime(now))
        validity.append(derUTCTime(tenYears))
        return derSequence(validity)
    }

    private func buildSubjectPublicKeyInfo(_ pkcs1Key: Data) -> Data {
        var info = Data()
        var algo = Data()
        algo.append(derOID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]))
        algo.append(derNull())
        info.append(derSequence(algo))
        info.append(derBitString(pkcs1Key))
        return derSequence(info)
    }

    private func signData(_ data: Data, with privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            log.error("Signing failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            throw CertificateError.signingFailed
        }
        return signature
    }

    // MARK: - DER Encoding Primitives

    private func derLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        } else if length < 256 {
            return Data([0x81, UInt8(length)])
        } else {
            return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
        }
    }

    private func derTag(_ tag: UInt8, _ contents: Data) -> Data {
        var result = Data([tag])
        result.append(derLength(contents.count))
        result.append(contents)
        return result
    }

    private func derSequence(_ contents: Data) -> Data { derTag(0x30, contents) }
    private func derSet(_ contents: Data) -> Data { derTag(0x31, contents) }

    private func derInteger(_ value: Data) -> Data {
        var bytes = value
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return derTag(0x02, bytes)
    }

    private func derBitString(_ contents: Data) -> Data {
        var value = Data([0x00])
        value.append(contents)
        return derTag(0x03, value)
    }

    private func derOID(_ bytes: [UInt8]) -> Data { derTag(0x06, Data(bytes)) }
    private func derNull() -> Data { Data([0x05, 0x00]) }
    private func derUTF8String(_ string: String) -> Data { derTag(0x0C, Data(string.utf8)) }

    private func derUTCTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let str = formatter.string(from: date) + "Z"
        return derTag(0x17, Data(str.utf8))
    }

    private func derExplicit(tag: Int, _ contents: Data) -> Data {
        derTag(UInt8(0xA0 | tag), contents)
    }
}
