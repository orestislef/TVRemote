import Foundation

struct TVDevice: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int
    var isPaired: Bool

    var displayName: String {
        name.isEmpty ? host : name
    }

    var pairingPort: Int {
        6467
    }
}
