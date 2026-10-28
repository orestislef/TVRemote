import Foundation
import Observation
import os

// TVDevice is defined in Models/TVDevice.swift
// RemoteCommand is defined in Models/RemoteCommand.swift
// BonjourDiscovery is defined in Services/BonjourDiscovery.swift
// AndroidTVPairing is defined in Services/AndroidTVPairing.swift
// AndroidTVConnection is defined in Services/AndroidTVConnection.swift

// Attempting to import the module to see if it resolves visibility issues
// import TVRemote

private let log = Logger(subsystem: "gr.orestislef.TVRemote", category: "TVManager")

@Observable
final class TVManager {
    var pairedDevices: [TVDevice] = []
    var activeDevice: TVDevice?

    let discovery = BonjourDiscovery()
    let pairing = AndroidTVPairing()
    let remoteConnection = AndroidTVConnection()

    private let storageKey = "paired_tv_devices"

    init() {
        log.info("TVManager initializing...")
        loadPairedDevices()
        log.info("TVManager ready, \(self.pairedDevices.count) paired device(s) loaded")
        autoConnect()
    }

    /// Automatically connects to the saved paired TV on app launch so the
    /// remote controls are immediately available.
    private func autoConnect() {
        guard let device = pairedDevices.first else { return }
        log.info("Auto-connecting to '\(device.displayName)'")
        Task {
            do {
                try await connectToDevice(device)
                log.info("Auto-connect succeeded for '\(device.displayName)'")
            } catch {
                log.warning("Auto-connect failed for '\(device.displayName)': \(error.localizedDescription) — user can connect manually")
            }
        }
    }

    // MARK: - Device Management

    func addPairedDevice(_ device: TVDevice) {
        var d = device
        d.isPaired = true
        if let idx = pairedDevices.firstIndex(where: { $0.id == d.id }) {
            log.info("Updating existing paired device: '\(device.displayName)' id=\(device.id)")
            pairedDevices[idx] = d
        } else {
            log.info("Adding new paired device: '\(device.displayName)' id=\(device.id) host=\(device.host):\(device.port)")
            pairedDevices.append(d)
        }
        savePairedDevices()
    }

    func removePairedDevice(_ device: TVDevice) {
        log.info("Removing paired device: '\(device.displayName)' id=\(device.id)")
        pairedDevices.removeAll { $0.id == device.id }
        if activeDevice?.id == device.id {
            log.info("Removed device was active, disconnecting")
            disconnect()
        }
        savePairedDevices()
    }

    // MARK: - Connection

    func connectToDevice(_ device: TVDevice) async throws {
        // Idempotent: skip if already connected to this device
        if activeDevice?.id == device.id && remoteConnection.isConnected {
            log.info("Already connected to '\(device.displayName)', reusing session")
            return
        }
        log.info("Connecting to device: '\(device.displayName)' host=\(device.host):\(device.port)")
        try await remoteConnection.connect(to: device)
        activeDevice = device
        log.info("Active device set to '\(device.displayName)'")
    }

    func disconnect() {
        log.info("Disconnecting from active device: '\(self.activeDevice?.displayName ?? "none")'")
        remoteConnection.disconnect()
        activeDevice = nil
        log.info("Disconnected, no active device")
    }

    func sendCommand(_ command: RemoteCommand) {
        log.info("Forwarding command '\(command.rawValue)' to active device '\(self.activeDevice?.displayName ?? "none")'")
        remoteConnection.sendCommand(command)
    }

    // MARK: - Pairing Flow

    func startPairing(device: TVDevice) async throws {
        log.info("Starting pairing flow for '\(device.displayName)' host=\(device.host) pairingPort=\(device.pairingPort)")
        try await pairing.startPairing(device: device)
        log.info("Pairing flow started, waiting for code entry")
    }

    func submitPairingCode(_ code: String, device: TVDevice) async throws {
        log.info("Submitting pairing code for '\(device.displayName)'")
        try await pairing.submitCode(code)
        log.info("Pairing code accepted, adding device to paired list")
        addPairedDevice(device)
    }

    // MARK: - Persistence

    private func savePairedDevices() {
        if let data = try? JSONEncoder().encode(pairedDevices) {
            UserDefaults.standard.set(data, forKey: storageKey)
            log.info("Saved \(self.pairedDevices.count) paired device(s) to UserDefaults")
        } else {
            log.error("Failed to encode paired devices for storage")
        }
    }

    private func loadPairedDevices() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            log.info("No paired devices data in UserDefaults")
            return
        }
        guard let devices = try? JSONDecoder().decode([TVDevice].self, from: data) else {
            log.error("Failed to decode paired devices from UserDefaults")
            return
        }
        pairedDevices = devices
        log.info("Loaded \(devices.count) paired device(s): \(devices.map { $0.displayName }.joined(separator: ", "))")
    }

    // MARK: - Watch Data

    func pairedDevicesPayload() -> [[String: Any]] {
        let payload = pairedDevices.map { device in
            [
                "id": device.id,
                "name": device.name,
                "host": device.host,
                "port": device.port,
                "isPaired": device.isPaired,
            ] as [String: Any]
        }
        log.info("Generated Watch payload: \(payload.count) device(s)")
        return payload
    }
}
