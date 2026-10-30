import Foundation
import Security

// Stands in for the real CertificateManager, which needs a real keychain and RSA.
// The real file is still type checked in step 2.
final class CertificateManager {
    static let shared = CertificateManager()
    var identityAvailable = true
    func getOrCreateIdentity() throws -> SecIdentity {
        guard identityAvailable else { throw CertificateError.identityNotFound }
        return SecIdentity()
    }
    func getClientCertificateData() -> Data? { Data([1, 2, 3]) }
    func getPrivateKeyData() -> Data? { Data([4, 5, 6]) }
}

enum CertificateError: Error {
    case identityNotFound
}

func fakeSetIdentityAvailable(_ available: Bool) {
    CertificateManager.shared.identityAvailable = available
}

typealias Conn = AndroidTVConnection
