import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager.shared
    @State private var selectedDevice: TVDevice?

    var body: some View {
        NavigationStack {
            Group {
                if session.pairedDevices.isEmpty && !session.isPhoneReachable {
                    // No cached devices and no phone
                    VStack(spacing: 12) {
                        Image(systemName: "iphone.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Open TVRemote\non your iPhone")
                            .multilineTextAlignment(.center)
                            .font(.headline)
                        Text("Pair your TVs from the iPhone app first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else if session.pairedDevices.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tv.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No Paired TVs")
                            .font(.headline)
                        Text("Use the iPhone app to discover and pair TVs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    // TV List
                    List(session.pairedDevices) { device in
                        Button {
                            connectTo(device)
                        } label: {
                            HStack {
                                Image(systemName: "tv.fill")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text(device.displayName)
                                        .font(.headline)
                                    if session.isConnecting && selectedDevice?.id == device.id {
                                        Text("Connecting...")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    } else {
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(session.hasCertificate ? .green : .orange)
                                                .frame(width: 6, height: 6)
                                            Text(session.hasCertificate ? "Direct" : "Via iPhone")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .disabled(session.isConnecting)
                    }
                }
            }
            .navigationTitle("TVRemote")
            .navigationDestination(item: $selectedDevice) { device in
                RemoteView(
                    deviceName: device.displayName,
                    onCommand: { cmd in
                        session.sendCommand(cmd)
                    },
                    onDisconnect: {
                        session.disconnectDevice()
                        selectedDevice = nil
                    }
                )
            }
            .onAppear {
                session.requestDevices()
            }
            .onChange(of: session.connectedDeviceId) { _, newId in
                // Auto-navigate when connection completes
                if let newId, selectedDevice == nil {
                    selectedDevice = session.pairedDevices.first { $0.id == newId }
                }
            }
        }
    }

    private func connectTo(_ device: TVDevice) {
        selectedDevice = device
        session.connectToDevice(device)
    }
}
