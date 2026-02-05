import Foundation
import WatchConnectivity
import Observation
import os

private let log = Logger(subsystem: "gr.orestislef.TVRemote.watchkitapp", category: "WatchSession")

@Observable
final class WatchSessionManager: NSObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    var pairedDevices: [TVDevice] = []
    var isPhoneReachable = false
    var connectedDeviceId: String?
    var isConnecting = false
    var lastError: String?
    var hasCertificate: Bool { WatchCertificateStore.shared.hasIdentity }

    let tvConnection = WatchTVConnection()

    private let devicesKey = "watch_paired_devices"

    override init() {
        super.init()
        log.info("WatchSessionManager initializing...")
        loadCachedDevices()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
            log.info("WCSession activated on Watch")
        } else {
            log.warning("WCSession not supported")
        }
    }

    // MARK: - Direct Connection (no iPhone needed)

    func connectToDevice(_ device: TVDevice) {
        guard !isConnecting else {
            log.warning("Already connecting, ignoring")
            return
        }

        // Try direct connection first if we have a certificate
        if hasCertificate {
            log.info("Attempting DIRECT connection to '\(device.displayName)' host=\(device.host):\(device.port)")
            isConnecting = true
            lastError = nil
            Task {
                do {
                    try await tvConnection.connect(to: device)
                    connectedDeviceId = device.id
                    isConnecting = false
                    log.info("Direct connection SUCCESS to '\(device.displayName)'")
                } catch {
                    log.error("Direct connection FAILED: \(error.localizedDescription)")
                    isConnecting = false
                    // Fallback to iPhone proxy if phone is reachable
                    if isPhoneReachable {
                        log.info("Falling back to iPhone proxy connection")
                        connectViaPhone(device)
                    } else {
                        lastError = error.localizedDescription
                    }
                }
            }
        } else if isPhoneReachable {
            log.info("No certificate on Watch, connecting via iPhone proxy")
            connectViaPhone(device)
        } else {
            log.error("No certificate and iPhone not reachable — cannot connect")
            lastError = "Open iPhone app to set up pairing first"
        }
    }

    func disconnectDevice() {
        log.info("Disconnecting device")
        tvConnection.disconnect()
        connectedDeviceId = nil

        // Also tell iPhone to disconnect if reachable
        if isPhoneReachable {
            WCSession.default.sendMessage(
                ["action": "disconnect"],
                replyHandler: nil,
                errorHandler: nil
            )
        }
    }

    func sendCommand(_ command: RemoteCommand) {
        // Use direct connection if available
        if tvConnection.isConnected {
            log.info("Sending command DIRECT: \(command.rawValue)")
            tvConnection.sendCommand(command)
        } else if isPhoneReachable {
            log.info("Sending command via iPhone: \(command.rawValue)")
            WCSession.default.sendMessage(
                ["action": "command", "command": command.rawValue],
                replyHandler: nil,
                errorHandler: { error in
                    log.error("Command relay error: \(error.localizedDescription)")
                }
            )
        } else {
            log.error("Cannot send command: no direct connection and iPhone not reachable")
            lastError = "Not connected"
        }
    }

    // MARK: - iPhone Proxy Connection (fallback)

    private func connectViaPhone(_ device: TVDevice) {
        isConnecting = true
        lastError = nil
        WCSession.default.sendMessage(
            ["action": "connect", "deviceId": device.id],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.isConnecting = false
                    if reply["status"] as? String == "connected" {
                        log.info("iPhone proxy connection SUCCESS for '\(device.displayName)'")
                        self?.connectedDeviceId = device.id
                    } else if let error = reply["error"] as? String {
                        log.error("iPhone proxy connection FAILED: \(error)")
                        self?.lastError = error
                    }
                }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.isConnecting = false
                    log.error("iPhone proxy message error: \(error.localizedDescription)")
                    self?.lastError = error.localizedDescription
                }
            }
        )
    }

    // MARK: - Device List

    func requestDevices() {
        guard WCSession.default.isReachable else {
            isPhoneReachable = false
            log.info("Phone not reachable, using cached devices (\(self.pairedDevices.count))")
            return
        }

        log.info("Requesting device list from iPhone")
        WCSession.default.sendMessage(["action": "getDevices"], replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.parseDevicesReply(reply)
            }
        }, errorHandler: { error in
            log.error("getDevices error: \(error.localizedDescription)")
        })
    }

    // MARK: - Certificate Import

    private func importCertificateFromContext(_ context: [String: Any]) {
        guard let keyData = context["privateKeyData"] as? Data,
              let certData = context["certificateData"] as? Data else {
            return
        }
        log.info("Importing certificate from context: key=\(keyData.count)B cert=\(certData.count)B")
        do {
            try WatchCertificateStore.shared.importIdentity(
                privateKeyData: keyData,
                certificateData: certData
            )
            log.info("Certificate imported successfully — Watch can now connect directly!")
        } catch {
            log.error("Certificate import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Parsing & Persistence

    private func parseDevicesReply(_ reply: [String: Any]) {
        guard let devicesData = reply["devices"] as? [[String: Any]] else { return }
        pairedDevices = devicesData.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String,
                  let host = dict["host"] as? String,
                  let port = dict["port"] as? Int else { return nil }
            return TVDevice(
                id: id,
                name: name,
                host: host,
                port: port,
                isPaired: true
            )
        }
        log.info("Parsed \(self.pairedDevices.count) paired device(s)")
        cacheDevices()
    }

    private func cacheDevices() {
        if let data = try? JSONEncoder().encode(pairedDevices) {
            UserDefaults.standard.set(data, forKey: devicesKey)
            log.debug("Cached \(self.pairedDevices.count) device(s) to UserDefaults")
        }
    }

    private func loadCachedDevices() {
        guard let data = UserDefaults.standard.data(forKey: devicesKey),
              let devices = try? JSONDecoder().decode([TVDevice].self, from: data) else {
            log.info("No cached devices on Watch")
            return
        }
        pairedDevices = devices
        log.info("Loaded \(devices.count) cached device(s) on Watch")
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let stateStr = switch activationState {
        case .activated: "activated"
        case .inactive: "inactive"
        case .notActivated: "notActivated"
        @unknown default: "unknown"
        }
        log.info("WCSession activation: \(stateStr)")
        if let error {
            log.error("WCSession activation error: \(error.localizedDescription)")
        }
        Task { @MainActor in
            self.isPhoneReachable = session.isReachable
            if activationState == .activated {
                // Load from received application context
                let ctx = session.receivedApplicationContext
                if !ctx.isEmpty {
                    if let devicesData = ctx["pairedDevices"] as? [[String: Any]] {
                        self.parseDevicesReply(["devices": devicesData])
                    }
                    self.importCertificateFromContext(ctx)
                }
                self.requestDevices()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        log.info("Phone reachability changed: \(session.isReachable)")
        Task { @MainActor in
            self.isPhoneReachable = session.isReachable
            if session.isReachable {
                self.requestDevices()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        log.info("Received applicationContext with keys: \(applicationContext.keys.joined(separator: ", "))")
        Task { @MainActor in
            if let devicesData = applicationContext["pairedDevices"] as? [[String: Any]] {
                self.parseDevicesReply(["devices": devicesData])
            }
            self.importCertificateFromContext(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        log.info("Received message from iPhone: \(message.keys.joined(separator: ", "))")
        Task { @MainActor in
            if let action = message["action"] as? String, action == "importCertificate" {
                self.importCertificateFromContext(message)
                replyHandler(["status": "ok"])
            } else {
                replyHandler(["error": "unknown action"])
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        log.info("Received message (no reply) from iPhone: \(message.keys.joined(separator: ", "))")
        Task { @MainActor in
            if let action = message["action"] as? String, action == "importCertificate" {
                self.importCertificateFromContext(message)
            }
        }
    }
}
