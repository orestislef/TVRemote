// NetService exists in Foundation on Apple platforms but not on Linux. Compiled into
// the target under test, with what the Bonjour tests need to drive it.
import Foundation

protocol NetServiceDelegate: NSObjectProtocol {
    func netServiceDidResolveAddress(_ sender: NetService)
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber])
}

final class NetService: NSObject {
    let domain: String
    let type: String
    let name: String
    weak var delegate: (any NetServiceDelegate)?
    var hostName: String?
    var port = -1
    var addresses: [Data]?
    nonisolated(unsafe) static var fakeAll: [NetService] = []
    private(set) var fakeResolving = false

    init(domain: String, type: String, name: String) {
        self.domain = domain
        self.type = type
        self.name = name
        super.init()
        NetService.fakeAll.append(self)
    }
    func resolve(withTimeout timeout: TimeInterval) { fakeResolving = true }
    func stop() { fakeResolving = false }
}
