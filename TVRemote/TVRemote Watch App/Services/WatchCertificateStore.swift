import Foundation
import Security
import os

nonisolated(unsafe) private let log = Logger(subsystem: "gr.orestislef.TVRemote.watchkitapp", category: "CertStore")

/// Stores and retrieves the TLS client identity on the Watch keychain.
/// The identity (private key + certificate) is transferred from iPhone after pairing.
final class WatchCertificateStore {
    static let shared = WatchCertificateStore()
    private let keyTag = "gr.orestislef.TVRemote.watchclientkey"
    private let certLabel = "TVRemote Watch Client"
    /// Old builds kept the private key here as a backup nobody read. Only purged now.
    private let legacyKeyDataKey = "watch_tls_key_data"
    /// Public data, kept to tell whether an incoming identity is new.
    private let certDataKey = "watch_tls_cert_data"

    private init() {
        UserDefaults.standard.removeObject(forKey: legacyKeyDataKey)
    }

    // MARK: - Import from iPhone

    /// Import a private key + certificate received from iPhone.
    /// - Parameters:
    ///   - privateKeyData: Raw private key bytes (PKCS1 format from SecKeyCopyExternalRepresentation)
    ///   - certificateData: DER-encoded certificate bytes
    func importIdentity(privateKeyData: Data, certificateData: Data) throws {
        log.info("Importing identity: key=\(privateKeyData.count)B cert=\(certificateData.count)B")

        // Parse everything before touching the keychain, and remove the old items
        // only after the new ones are in. A failed import keeps the working identity.
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(
            privateKeyData as CFData,
            keyAttributes as CFDictionary,
            &error
        ) else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "unknown"
            log.error("Failed to create SecKey from data: \(desc)")
            throw CertStoreError.keyImportFailed(desc)
        }
        log.info("SecKey created from imported data")

        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            log.error("Failed to create SecCertificate from DER data")
            throw CertStoreError.certImportFailed
        }

        let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "unknown"
        log.info("Certificate created: subject='\(summary)'")

        let oldKeys = existingItems(matching: [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
        ])
        let oldCerts = existingItems(matching: [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel,
        ])

        // Store key in keychain
        let addKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecValueRef as String: privateKey,
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let keyStatus = SecItemAdd(addKeyQuery as CFDictionary, nil)
        if keyStatus == errSecSuccess {
            log.info("Private key stored in Watch keychain")
        } else if keyStatus == errSecDuplicateItem {
            log.info("Private key already in Watch keychain (duplicate)")
        } else {
            log.error("Failed to store private key: OSStatus=\(keyStatus)")
            throw CertStoreError.keychainError(keyStatus)
        }

        // Store certificate
        let addCertQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certLabel,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let certStatus = SecItemAdd(addCertQuery as CFDictionary, nil)
        if certStatus == errSecSuccess {
            log.info("Certificate stored in Watch keychain")
        } else if certStatus == errSecDuplicateItem {
            log.info("Certificate already in Watch keychain (duplicate)")
        } else {
            log.error("Failed to store certificate: OSStatus=\(certStatus)")
            throw CertStoreError.keychainError(certStatus)
        }

        // A duplicate means the old item is the new one, so it has to stay.
        if keyStatus == errSecSuccess { deleteItems(oldKeys, itemClass: kSecClassKey) }
        if certStatus == errSecSuccess { deleteItems(oldCerts, itemClass: kSecClassCertificate) }

        UserDefaults.standard.set(certificateData, forKey: certDataKey)
    }

    /// True when this certificate is already imported and its identity still resolves.
    func hasImported(certificateData: Data) -> Bool {
        UserDefaults.standard.data(forKey: certDataKey) == certificateData && hasIdentity
    }

    // MARK: - Retrieve Identity

    func getIdentity() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            log.info("Found TLS identity in Watch keychain")
            return (item as! SecIdentity)
        }
        log.debug("No identity in Watch keychain (OSStatus=\(status))")
        return nil
    }

    var hasIdentity: Bool {
        getIdentity() != nil
    }

    // MARK: - Cleanup

    private func existingItems(matching query: [String: Any]) -> [AnyObject] {
        var search = query
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        search[kSecReturnRef as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess else { return [] }
        return result as? [AnyObject] ?? []
    }

    private func deleteItems(_ items: [AnyObject], itemClass: CFString) {
        for item in items {
            let query: [String: Any] = [
                kSecClass as String: itemClass,
                kSecValueRef as String: item,
            ]
            let status = SecItemDelete(query as CFDictionary)
            log.debug("deleteItems: OSStatus=\(status)")
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

    func deleteAll() {
        log.info("Deleting all Watch identity data")
        deleteExistingKey()
        deleteExistingCert()
        UserDefaults.standard.removeObject(forKey: legacyKeyDataKey)
        UserDefaults.standard.removeObject(forKey: certDataKey)
    }
}

enum CertStoreError: Error, LocalizedError {
    case keyImportFailed(String)
    case certImportFailed
    case keychainError(OSStatus)
    case noIdentity

    var errorDescription: String? {
        switch self {
        case .keyImportFailed(let msg): return "Key import failed: \(msg)"
        case .certImportFailed: return "Certificate import failed"
        case .keychainError(let status): return "Keychain error: \(status)"
        case .noIdentity: return "No TLS identity available"
        }
    }
}
