import Foundation
import UIKit
import WatchConnectivity
import Observation
import os

private let log = Logger(subsystem: "gr.orestislef.TVRemote", category: "PhoneSession")

@Observable
final class PhoneSessionManager: NSObject, WCSessionDelegate {
    static let shared = PhoneSessionManager()
    var tvManager: TVManager?

    var isPaired = false
    var isWatchAppInstalled = false
    var isReachable = false

    override init() {
        super.init()
        log.info("PhoneSessionManager initializing...")
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
            log.info("WCSession activated")
        } else {
            log.warning("WCSession not supported on this device")
        }
    }

    func refreshStatus() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let oldPaired = isPaired
        let oldInstalled = isWatchAppInstalled
        let oldReachable = isReachable
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
        if isPaired != oldPaired || isWatchAppInstalled != oldInstalled || isReachable != oldReachable {
            log.info("Watch status changed: paired=\(self.isPaired) installed=\(self.isWatchAppInstalled) reachable=\(self.isReachable)")
        }
    }

    func openWatchAppSettings() {
        log.info("Opening Watch app settings via itms-watchs://")
        if let url = URL(string: "itms-watchs://") {
            UIApplication.shared.open(url)
        }
    }

    func sendPairedDevicesToWatch() {
        guard WCSession.default.activationState == .activated else {
            log.warning("sendPairedDevicesToWatch: session not activated")
            return
        }
        guard let tvManager else {
            log.warning("sendPairedDevicesToWatch: tvManager is nil")
            return
        }

        // Include TLS certificate data so Watch can connect directly
        var context: [String: Any] = [
            "pairedDevices": tvManager.pairedDevicesPayload()
        ]

        if let keyData = CertificateManager.shared.getPrivateKeyData(),
           let certData = CertificateManager.shared.getClientCertificateData() {
            context["privateKeyData"] = keyData
            context["certificateData"] = certData
            log.info("Including TLS identity in context: key=\(keyData.count)B cert=\(certData.count)B")
        } else {
            log.warning("TLS identity not available, Watch will need iPhone for commands")
        }

        do {
            try WCSession.default.updateApplicationContext(context)
            log.info("Sent \(tvManager.pairedDevices.count) paired device(s) + identity to Watch via applicationContext")
        } catch {
            log.error("Failed to update applicationContext: \(error.localizedDescription)")
        }
    }

    /// Explicitly send the TLS certificate to Watch (called after successful pairing).
    func sendCertificateToWatch() {
        guard WCSession.default.isReachable else {
            log.info("Watch not reachable, certificate will be sent via applicationContext on next sync")
            sendPairedDevicesToWatch()
            return
        }
        guard let keyData = CertificateManager.shared.getPrivateKeyData(),
              let certData = CertificateManager.shared.getClientCertificateData() else {
            log.error("Cannot send certificate: identity not available")
            return
        }

        let message: [String: Any] = [
            "action": "importCertificate",
            "privateKeyData": keyData,
            "certificateData": certData,
        ]
        log.info("Sending TLS certificate to Watch via sendMessage (key=\(keyData.count)B cert=\(certData.count)B)")
        WCSession.default.sendMessage(message, replyHandler: { reply in
            log.info("Watch certificate import reply: \(reply)")
        }, errorHandler: { error in
            log.error("Failed to send certificate to Watch: \(error.localizedDescription)")
        })
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
        if let error {
            log.error("WCSession activation completed: \(stateStr), error: \(error.localizedDescription)")
        } else {
            log.info("WCSession activation completed: \(stateStr)")
        }
        Task { @MainActor in
            self.refreshStatus()
            if activationState == .activated {
                self.sendPairedDevicesToWatch()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        log.info("WCSession became inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        log.info("WCSession deactivated, reactivating...")
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        log.info("Watch state changed: paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)")
        Task { @MainActor in
            self.refreshStatus()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        log.info("Watch reachability changed: \(session.isReachable)")
        Task { @MainActor in
            self.refreshStatus()
        }
    }

    // Handle messages from Watch
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        log.info("Received message from Watch: \(message.keys.joined(separator: ", "))")
        Task { @MainActor in
            self.handleWatchMessage(message, replyHandler: replyHandler)
        }
    }

    @MainActor
    private func handleWatchMessage(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let tvManager else {
            log.error("handleWatchMessage: tvManager is nil, cannot process")
            replyHandler(["error": "TV Manager not available"])
            return
        }

        if let action = message["action"] as? String {
            log.info("Processing Watch action: '\(action)'")
            switch action {
            case "getDevices":
                let payload = tvManager.pairedDevicesPayload()
                log.info("Replying with \(payload.count) device(s)")
                replyHandler(["devices": payload])

            case "connect":
                if let deviceId = message["deviceId"] as? String,
                   let device = tvManager.pairedDevices.first(where: { $0.id == deviceId }) {
                    log.info("Watch requested connect to '\(device.displayName)' id=\(deviceId)")
                    Task {
                        do {
                            try await tvManager.connectToDevice(device)
                            log.info("Watch connect success for '\(device.displayName)'")
                            replyHandler(["status": "connected"])
                        } catch {
                            log.error("Watch connect failed for '\(device.displayName)': \(error.localizedDescription)")
                            replyHandler(["error": error.localizedDescription])
                        }
                    }
                } else {
                    let deviceId = message["deviceId"] as? String ?? "nil"
                    log.error("Watch connect: device not found, id=\(deviceId)")
                    replyHandler(["error": "Device not found"])
                }

            case "disconnect":
                log.info("Watch requested disconnect")
                tvManager.disconnect()
                replyHandler(["status": "disconnected"])

            case "command":
                if let cmdStr = message["command"] as? String,
                   let command = RemoteCommand(rawValue: cmdStr) {
                    log.info("Watch sent command: '\(cmdStr)'")
                    tvManager.sendCommand(command)
                    replyHandler(["status": "ok"])
                } else {
                    let cmdStr = message["command"] as? String ?? "nil"
                    log.error("Watch sent unknown command: '\(cmdStr)'")
                    replyHandler(["error": "Unknown command"])
                }

            default:
                log.warning("Watch sent unknown action: '\(action)'")
                replyHandler(["error": "Unknown action"])
            }
        }
    }
}
