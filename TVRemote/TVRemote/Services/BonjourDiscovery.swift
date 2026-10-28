import Foundation
import Network
import Observation
import os

@MainActor
private let log = Logger(subsystem: "gr.orestislef.TVRemote", category: "Bonjour")

@Observable
final class BonjourDiscovery {
    var discoveredDevices: [TVDevice] = []
    var isSearching = false

    private var browser: NWBrowser?

    func startDiscovery() {
        guard !isSearching else {
            log.info("Discovery already running, skipping")
            return
        }
        isSearching = true
        print("[DISC] Starting Bonjour discovery for _androidtvremote2._tcp")

        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_androidtvremote2._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    print("[DISC] Browser state: ready")
                case .failed(let error):
                    print("[DISC] Browser state: FAILED - \(error.localizedDescription)")
                    self?.isSearching = false
                case .cancelled:
                    log.info("Browser state: cancelled")
                    self?.isSearching = false
                case .waiting(let error):
                    print("[DISC] Browser state: WAITING - \(error.localizedDescription) (code \((error as? NWError)?.errorCode ?? -1))")
                default:
                    log.debug("Browser state: \(String(describing: state))")
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                print("[DISC] Browse results changed: \(results.count) results, \(changes.count) changes")
                self?.handleResults(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stopDiscovery() {
        log.info("Stopping Bonjour discovery")
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            if case let .service(name, type, domain, interface) = result.endpoint {
                print("[DISC] Found service: name='\(name)' type='\(type)' domain='\(domain)'")
                resolveService(result: result, name: name)
            }
        }
    }

    private var pendingResolvers: [ServiceResolver] = []

    private func resolveService(result: NWBrowser.Result, name: String) {
        print("[DISC] Resolving service '\(name)' via NSNetService...")
        let resolver = ServiceResolver(name: name) { [weak self] ipv4, port in
            Task { @MainActor in
                guard let self, let ipv4 else {
                    print("[DISC] Resolution failed for '\(name)'")
                    return
                }
                print("[DISC] ADDED DEVICE: '\(name)' at \(ipv4):\(port)")
                let device = TVDevice(
                    id: "\(ipv4):\(port)",
                    name: name,
                    host: ipv4,
                    port: Int(port),
                    isPaired: false
                )
                if !self.discoveredDevices.contains(where: { $0.id == device.id }) {
                    self.discoveredDevices.append(device)
                }
            }
        }
        pendingResolvers.append(resolver)
        resolver.start()
    }
}

final class ServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private let completion: (String?, UInt16) -> Void
    private var finished = false

    init(name: String, completion: @escaping (String?, UInt16) -> Void) {
        service = NetService(domain: "local", type: "_androidtvremote2._tcp.", name: name)
        self.completion = completion
        super.init()
    }

    func start() {
        service.delegate = self
        service.resolve(withTimeout: 6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in
            guard let self, !self.finished else { return }
            print("[DISC] NSNetService resolution timeout")
            self.finish(nil, 0)
        }
    }

    private func finish(_ ip: String?, _ port: UInt16) {
        guard !finished else { return }
        finished = true
        service.stop()
        completion(ip, port)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        print("[DISC] NSNetService resolved: \(sender.hostName ?? "nil") port=\(sender.port) addrs=\(sender.addresses?.count ?? 0)")
        var port = UInt16(truncatingIfNeeded: max(sender.port, 0))
        if port == 0 {
            port = 6466
            print("[DISC] Port missing from mDNS record, defaulting to 6466")
        }
        for addrData in sender.addresses ?? [] {
            guard addrData.count >= MemoryLayout<sockaddr>.size else { continue }
            let sa: sockaddr = addrData.withUnsafeBytes { $0.load(as: sockaddr.self) }
            var saCopy = sa
            if saCopy.sa_family == UInt8(AF_INET) {
                let in4 = withUnsafePointer(to: &saCopy) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee } }
                var addr = in4.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buf)
                    print("[DISC] Got IPv4: \(ip)")
                    finish(ip, port)
                    return
                }
            }
        }
        print("[DISC] Resolved but no IPv4 address family found")
        finish(nil, 0)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("[DISC] NSNetService didNotResolve: \(errorDict)")
        finish(nil, 0)
    }

}
