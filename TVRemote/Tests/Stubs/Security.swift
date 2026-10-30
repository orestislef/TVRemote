// Mirrors the Security symbols used by the repo. CF types are Foundation aliases,
// which is the closest Linux gets to the toll-free bridging on Apple platforms.
import Foundation

public typealias OSStatus = Int32
public typealias CFData = NSData
public typealias CFDictionary = NSDictionary
public typealias CFString = NSString
public typealias CFArray = NSArray
public typealias CFTypeRef = AnyObject
public typealias CFError = NSError
public typealias CFAllocator = NSObject

public let errSecSuccess: OSStatus = 0
public let errSecItemNotFound: OSStatus = -25300
public let errSecDuplicateItem: OSStatus = -25299
public let errSecInteractionNotAllowed: OSStatus = -25308

public final class SecIdentity: @unchecked Sendable { public init() {} }
public final class SecCertificate: @unchecked Sendable { public init() {} }
public final class SecKey: @unchecked Sendable { public init() {} }
public final class SecTrust: @unchecked Sendable { public init() {} }

public struct SecKeyAlgorithm: Sendable {
    public static let rsaSignatureMessagePKCS1v15SHA256 = SecKeyAlgorithm()
}
public final class SecRandom: @unchecked Sendable { init() {} }
public typealias SecRandomRef = SecRandom
nonisolated(unsafe) public let kSecRandomDefault: SecRandomRef? = nil

nonisolated(unsafe) public let kSecClass: CFString = "class"
nonisolated(unsafe) public let kSecClassKey: CFString = "keys"
nonisolated(unsafe) public let kSecClassCertificate: CFString = "cert"
nonisolated(unsafe) public let kSecClassIdentity: CFString = "idnt"
nonisolated(unsafe) public let kSecAttrApplicationTag: CFString = "atag"
nonisolated(unsafe) public let kSecAttrKeyClass: CFString = "kcls"
nonisolated(unsafe) public let kSecAttrKeyClassPrivate: CFString = "1"
nonisolated(unsafe) public let kSecAttrKeyClassPublic: CFString = "0"
nonisolated(unsafe) public let kSecAttrKeyType: CFString = "type"
nonisolated(unsafe) public let kSecAttrKeyTypeRSA: CFString = "42"
nonisolated(unsafe) public let kSecAttrKeySizeInBits: CFString = "bsiz"
nonisolated(unsafe) public let kSecAttrIsPermanent: CFString = "perm"
nonisolated(unsafe) public let kSecAttrAccessible: CFString = "pdmn"
nonisolated(unsafe) public let kSecAttrAccessibleAfterFirstUnlock: CFString = "ck"
nonisolated(unsafe) public let kSecAttrLabel: CFString = "labl"
nonisolated(unsafe) public let kSecPrivateKeyAttrs: CFString = "private"
nonisolated(unsafe) public let kSecReturnRef: CFString = "r_Ref"
nonisolated(unsafe) public let kSecReturnData: CFString = "r_Data"
nonisolated(unsafe) public let kSecValueRef: CFString = "v_Ref"
nonisolated(unsafe) public let kSecMatchLimit: CFString = "m_Limit"
nonisolated(unsafe) public let kSecMatchLimitAll: CFString = "m_LimitAll"
nonisolated(unsafe) public let kSecMatchLimitOne: CFString = "m_LimitOne"

public func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { errSecItemNotFound }
public func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { errSecSuccess }
public func SecItemDelete(_ query: CFDictionary) -> OSStatus { errSecSuccess }
public func SecKeyCreateRandomKey(_ parameters: CFDictionary, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> SecKey? { SecKey() }
public func SecKeyCreateWithData(_ keyData: CFData, _ attributes: CFDictionary, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> SecKey? { SecKey() }
public func SecKeyCopyPublicKey(_ key: SecKey) -> SecKey? { SecKey() }
public func SecKeyCopyExternalRepresentation(_ key: SecKey, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFData? { NSData() }
public func SecKeyCreateSignature(_ key: SecKey, _ algorithm: SecKeyAlgorithm, _ dataToSign: CFData, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFData? { NSData() }
public func SecCertificateCreateWithData(_ allocator: CFAllocator?, _ data: CFData) -> SecCertificate? { SecCertificate() }
public func SecCertificateCopySubjectSummary(_ certificate: SecCertificate) -> CFString? { nil }
public func SecCertificateCopyData(_ certificate: SecCertificate) -> CFData { NSData() }
public func SecCertificateCopyKey(_ certificate: SecCertificate) -> SecKey? { SecKey() }
public func SecIdentityCopyCertificate(_ identityRef: SecIdentity, _ certificateRef: UnsafeMutablePointer<SecCertificate?>) -> OSStatus { errSecSuccess }
public func SecRandomCopyBytes(_ rnd: SecRandomRef?, _ count: Int, _ bytes: UnsafeMutableRawPointer) -> Int32 { 0 }
public func SecTrustCopyCertificateChain(_ trust: SecTrust) -> CFArray? { nil }

// sec_protocol: signatures from developer.apple.com/documentation/security.
public final class sec_protocol_options_t: @unchecked Sendable { public init() {} }
public final class sec_identity_t: @unchecked Sendable { public init() {} }
public final class sec_trust_t: @unchecked Sendable { public init() {} }
public final class sec_protocol_metadata_t: @unchecked Sendable { public init() {} }
public enum tls_protocol_version_t: UInt16, Sendable { case TLSv10 = 0x0301, TLSv11 = 0x0302, TLSv12 = 0x0303, TLSv13 = 0x0304, DTLSv10 = 0xfeff, DTLSv12 = 0xfefd }
public typealias dispatch_queue_t = DispatchQueue
public typealias sec_protocol_verify_complete_t = (Bool) -> Void
public typealias sec_protocol_verify_t = (sec_protocol_metadata_t, sec_trust_t, @escaping sec_protocol_verify_complete_t) -> Void

public func sec_protocol_options_set_min_tls_protocol_version(_ options: sec_protocol_options_t, _ version: tls_protocol_version_t) {}
public func sec_protocol_options_set_max_tls_protocol_version(_ options: sec_protocol_options_t, _ version: tls_protocol_version_t) {}
public func sec_protocol_options_set_local_identity(_ options: sec_protocol_options_t, _ identity: sec_identity_t) {}
public func sec_protocol_options_set_verify_block(_ options: sec_protocol_options_t, _ verify_block: @escaping sec_protocol_verify_t, _ verify_block_queue: dispatch_queue_t) {}
public func sec_identity_create(_ identity: SecIdentity) -> sec_identity_t? { sec_identity_t() }
public func sec_trust_copy_ref(_ trust: sec_trust_t) -> Unmanaged<SecTrust> { Unmanaged.passRetained(SecTrust()) }
