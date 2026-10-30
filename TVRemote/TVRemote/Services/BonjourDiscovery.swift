import Foundation
import Network
import Observation
import os

@MainActor
private let log = Logger(subsystem: "gr.orestislef.TVRemote", category: "Bonjour")

private let serviceType = "_androidtvremote2._tcp"
private let searchIndicatorSeconds: Double = 8

@Observable
final class BonjourDiscovery {
    /// Rebuilt from the live browse results, so a TV that leaves drops off the list.
    var discoveredDevices: [TVDevice] = []
    /// True for a limited time after a search starts. The browser keeps running
    /// after this, so a TV that turns up later still appears.
    var isSearching = false

    /// Every successful resolve, which includes a known TV at a new address.
    @ObservationIgnored var onDeviceResolved: ((TVDevice) -> Void)?

    @ObservationIgnored private var browser: NWBrowser?
    /// Bumped per browser, so callbacks from an old one are ignored.
    @ObservationIgnored private var browseID = 0
    @ObservationIgnored private var resolvers: [String: ServiceResolver] = [:]
    @ObservationIgnored private var resolved: [String: TVDevice] = [:]
    @ObservationIgnored private var indicatorTask: Task<Void, Never>?
    @ObservationIgnored private var isSearchRequested = false
    @ObservationIgnored private var isProbing = false

    func startDiscovery() {
        print("[DISC] Starting Bonjour discovery for \(serviceType)")
        isSearchRequested = true
        isSearching = true
        resolved = [:]
        discoveredDevices = []
        startBrowser()

        indicatorTask?.cancel()
        indicatorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(searchIndicatorSeconds))
            guard !Task.isCancelled else { return }
            self?.isSearching = false
        }
    }

    func stopDiscovery() {
        log.info("Stopping Bonjour discovery")
        isSearchRequested = false
        isSearching = false
        indicatorTask?.cancel()
        indicatorTask = nil
        if !isProbing { stopBrowser() }
    }

    /// A quiet browse for TVManager that doesn't disturb a search the Discover tab started.
    func startProbe() {
        isProbing = true
        if browser == nil {
            startBrowser()
        } else {
            for name in resolved.keys where resolvers[name] == nil {
                resolveService(name: name)
            }
        }
    }

    func stopProbe() {
        isProbing = false
        if !isSearchRequested { stopBrowser() }
    }

    private func startBrowser() {
        stopBrowser()
        browseID += 1
        let id = browseID

        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.browseID == id else { return }
                switch state {
                case .ready:
                    print("[DISC] Browser state: ready")
                case .failed(let error):
                    print("[DISC] Browser state: FAILED - \(error.localizedDescription)")
                    self.stopBrowser()
                    self.isSearching = false
                case .cancelled:
                    log.info("Browser state: cancelled")
                case .waiting(let error):
                    print("[DISC] Browser state: WAITING - \(error.localizedDescription)")
                default:
                    log.debug("Browser state: \(String(describing: state))")
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.browseID == id else { return }
                print("[DISC] Browse results changed: \(results.count) results")
                self.handleResults(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    private func stopBrowser() {
        browseID += 1
        browser?.cancel()
        browser = nil
        for resolver in resolvers.values { resolver.cancel() }
        resolvers = [:]
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var names = Set<String>()
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint {
                names.insert(name)
            }
        }

        for (name, resolver) in resolvers where !names.contains(name) {
            resolver.cancel()
            resolvers[name] = nil
        }
        resolved = resolved.filter { names.contains($0.key) }
        publishResolved()

        // Resolve again even when known: the name stays the same across an IP change.
        for name in names where resolvers[name] == nil {
            resolveService(name: name)
        }
    }

    private func resolveService(name: String) {
        print("[DISC] Resolving service '\(name)' via NSNetService...")
        let id = browseID
        let resolver = ServiceResolver(name: name) { [weak self] ipv4, port in
            Task { @MainActor in
                guard let self, self.browseID == id else { return }
                self.resolvers[name] = nil
                guard let ipv4 else {
                    print("[DISC] Resolution failed for '\(name)'")
                    return
                }
                print("[DISC] Resolved '\(name)' at \(ipv4):\(port)")
                let device = TVDevice(
                    id: "\(ipv4):\(port)",
                    name: name,
                    host: ipv4,
                    port: Int(port),
                    isPaired: false
                )
                self.resolved[name] = device
                self.publishResolved()
                self.onDeviceResolved?(device)
            }
        }
        resolvers[name] = resolver
        resolver.start()
    }

    private func publishResolved() {
        let devices = resolved.values.sorted { $0.displayName < $1.displayName }
        if devices != discoveredDevices { discoveredDevices = devices }
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

    /// Stops without calling the completion.
    func cancel() {
        guard !finished else { return }
        finished = true
        service.stop()
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
