import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager.shared
    @State private var selectedDevice: TVDevice?

    var body: some View {
        NavigationStack {
            Group {
                if session.pairedDevices.isEmpty && !session.isPhoneReachable {
                    VStack(spacing: 8) {
                        Image(systemName: "iphone.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Open TVRemote\non your iPhone")
                            .multilineTextAlignment(.center)
                            .font(.caption)
                        Text("Pair your TVs from the iPhone app first.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else if session.pairedDevices.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tv.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No Paired TVs")
                            .font(.caption)
                        Text("Use the iPhone app to pair TVs.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List(session.pairedDevices) { device in
                        Button {
                            connectTo(device)
                        } label: {
                            HStack {
                                Image(systemName: "tv.fill")
                                    .foregroundStyle(.blue)
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.displayName)
                                        .font(.caption)
                                        .lineLimit(1)
                                    if session.isConnecting && selectedDevice?.id == device.id {
                                        Text("Connecting...")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    } else {
                                        HStack(spacing: 3) {
                                            Circle()
                                                .fill(session.hasCertificate ? .green : .orange)
                                                .frame(width: 5, height: 5)
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
