import Foundation

struct TVDevice: Codable, Identifiable, Hashable {
    /// Stable record key. It was "ip:port" at pairing time, so don't read it as
    /// the current address after the TV's IP has changed.
    let id: String
    let name: String
    var host: String
    var port: Int
    var isPaired: Bool

    var displayName: String {
        name.isEmpty ? host : name
    }

    var pairingPort: Int {
        6467
    }
}
