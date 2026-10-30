import Foundation
import Security

// Stands in for the real WatchCertificateStore, which needs a real keychain.
// The real file is still type checked in step 2.
final class WatchCertificateStore {
    static let shared = WatchCertificateStore()
    var identityAvailable = true
    var importCount = 0
    var hasIdentity: Bool { identityAvailable }
    func getIdentity() -> SecIdentity? { identityAvailable ? SecIdentity() : nil }
    func hasImported(certificateData: Data) -> Bool { false }
    func importIdentity(privateKeyData: Data, certificateData: Data) throws {
        importCount += 1
        identityAvailable = true
    }
}

func fakeSetIdentityAvailable(_ available: Bool) {
    WatchCertificateStore.shared.identityAvailable = available
}

typealias Conn = WatchTVConnection
