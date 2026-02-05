import SwiftUI

struct PairedTVsView: View {
    @Environment(TVManager.self) private var tvManager

    var body: some View {
        List {
            if tvManager.pairedDevices.isEmpty {
                ContentUnavailableView(
                    "No Paired TVs",
                    systemImage: "tv.slash",
                    description: Text("Go to the Discover tab to find and pair Android TVs.")
                )
            }

            ForEach(tvManager.pairedDevices) { device in
                HStack {
                    Image(systemName: "tv.fill")
                        .font(.title2)
                        .foregroundStyle(tvManager.activeDevice?.id == device.id ? .green : .blue)

                    VStack(alignment: .leading) {
                        Text(device.displayName)
                            .font(.headline)
                        Text(device.host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if tvManager.activeDevice?.id == device.id {
                            Text("Connected")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }

                    Spacer()

                    if tvManager.activeDevice?.id == device.id {
                        Button("Disconnect") {
                            tvManager.disconnect()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else {
                        Button("Connect") {
                            Task {
                                try? await tvManager.connectToDevice(device)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        tvManager.removePairedDevice(device)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }

            if tvManager.remoteConnection.isConnected {
                Section("Remote Control") {
                    PhoneRemoteView()
                }
            }
        }
        .navigationTitle("My TVs")
    }
}

// MARK: - Simple Phone Remote (for testing)

struct PhoneRemoteView: View {
    @Environment(TVManager.self) private var tvManager

    var body: some View {
        VStack(spacing: 16) {
            // Power
            HStack {
                Spacer()
                Button { tvManager.sendCommand(.power) } label: {
                    Image(systemName: "power")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
            }

            // D-Pad
            VStack(spacing: 4) {
                remoteButton(.up, icon: "chevron.up")
                HStack(spacing: 4) {
                    remoteButton(.left, icon: "chevron.left")
                    remoteButton(.ok, label: "OK")
                    remoteButton(.right, icon: "chevron.right")
                }
                remoteButton(.down, icon: "chevron.down")
            }

            HStack(spacing: 20) {
                remoteButton(.back, icon: "arrow.uturn.backward")
                remoteButton(.home, icon: "house")
            }

            // Volume
            HStack(spacing: 20) {
                remoteButton(.volumeDown, icon: "speaker.minus")
                remoteButton(.mute, icon: "speaker.slash")
                remoteButton(.volumeUp, icon: "speaker.plus")
            }

            // Channels
            HStack(spacing: 20) {
                remoteButton(.channelDown, label: "CH-")
                remoteButton(.channelUp, label: "CH+")
            }
        }
        .padding()
    }

    private func remoteButton(_ cmd: RemoteCommand, icon: String? = nil, label: String? = nil) -> some View {
        Button {
            tvManager.sendCommand(cmd)
        } label: {
            if let icon {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 56, height: 44)
            } else if let label {
                Text(label)
                    .font(.headline)
                    .frame(width: 56, height: 44)
            }
        }
        .buttonStyle(.bordered)
    }
}
