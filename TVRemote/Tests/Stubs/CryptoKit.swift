// Only enough of SHA256 for type checking. The digest is not a real hash.
import Foundation
public struct SHA256Digest: Sequence, Sendable {
    let bytes: [UInt8]
    public func makeIterator() -> Array<UInt8>.Iterator { bytes.makeIterator() }
}
public struct SHA256: Sendable {
    public typealias Digest = SHA256Digest
    public init() {}
    public mutating func update(data: some DataProtocol) {}
    public func finalize() -> SHA256Digest { SHA256Digest(bytes: [UInt8](repeating: 0, count: 32)) }
    public static func hash(data: some DataProtocol) -> SHA256Digest { SHA256Digest(bytes: [UInt8](repeating: 0, count: 32)) }
}
