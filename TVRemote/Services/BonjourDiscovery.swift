import Foundation
import Network
import Observation
import os

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
        discoveredDevices.removeAll()
        isSearching = true
        log.info("Starting Bonjour discovery for _androidtvremote2._tcp")

        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_androidtvremote2._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    log.info("Browser state: ready - listening for services")
                case .failed(let error):
                    log.error("Browser state: FAILED - \(error.localizedDescription)")
                    self?.isSearching = false
                case .cancelled:
                    log.info("Browser state: cancelled")
                    self?.isSearching = false
                case .waiting(let error):
                    log.warning("Browser state: waiting - \(error.localizedDescription)")
                default:
                    log.debug("Browser state: \(String(describing: state))")
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                log.info("Browse results changed: \(results.count) results, \(changes.count) changes")
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
                log.info("Found service: name='\(name)' type='\(type)' domain='\(domain ?? "nil")' interface=\(String(describing: interface))")
                resolveService(result: result, name: name)
            }
        }
    }

    private func resolveService(result: NWBrowser.Result, name: String) {
        log.info("Resolving service '\(name)'...")
        let params = NWParameters.tcp
        let connection = NWConnection(to: result.endpoint, using: params)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let path = connection.currentPath,
                   let endpoint = path.remoteEndpoint {
                    log.info("Resolved '\(name)' -> endpoint: \(String(describing: endpoint))")
                    Task { @MainActor in
                        self?.addResolved(name: name, endpoint: endpoint)
                    }
                } else {
                    log.warning("Resolved '\(name)' but no remote endpoint available")
                }
                connection.cancel()
            case .failed(let error):
                log.error("Failed to resolve '\(name)': \(error.localizedDescription)")
                connection.cancel()
            case .waiting(let error):
                log.warning("Waiting to resolve '\(name)': \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: .main)

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if connection.state != .cancelled {
                log.warning("Resolution timeout for '\(name)', cancelling")
                connection.cancel()
            }
        }
    }

    private func addResolved(name: String, endpoint: NWEndpoint) {
        if case let .hostPort(host, port) = endpoint {
            let hostStr: String
            switch host {
            case .ipv4(let addr):
                hostStr = "\(addr)"
            case .ipv6(let addr):
                hostStr = "\(addr)"
            case .name(let hostname, _):
                hostStr = hostname
            @unknown default:
                hostStr = "\(host)"
            }

            let device = TVDevice(
                id: "\(hostStr):\(port.rawValue)",
                name: name,
                host: hostStr,
                port: Int(port.rawValue),
                isPaired: false
            )

            if !discoveredDevices.contains(where: { $0.id == device.id }) {
                log.info("Added device: '\(device.displayName)' at \(hostStr):\(port.rawValue)")
                discoveredDevices.append(device)
            } else {
                log.debug("Device already known: '\(device.displayName)' at \(hostStr):\(port.rawValue)")
            }
        }
    }
}
