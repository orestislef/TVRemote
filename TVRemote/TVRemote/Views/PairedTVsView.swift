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
                NavigationLink {
                    PhoneRemoteView(device: device)
                } label: {
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

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                Section("Quick Controls") {
                    QuickRemoteControls()
                }
            }
        }
        .navigationTitle("My TVs")
    }
}

// MARK: - Compact inline remote shown under the paired list

struct QuickRemoteControls: View {
    @Environment(TVManager.self) private var tvManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach([RemoteCommand.power, .volumeUp, .volumeDown, .mute, .up, .down, .left, .right, .ok, .back, .home, .channelUp, .channelDown], id: \.self) { cmd in
                    Button { tvManager.sendCommand(cmd) } label: {
                        Image(systemName: iconName(for: cmd))
                            .frame(width: 44, height: 40)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func iconName(for cmd: RemoteCommand) -> String {
        switch cmd {
        case .power: return "power"
        case .volumeUp: return "speaker.plus"
        case .volumeDown: return "speaker.minus"
        case .mute: return "speaker.slash"
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        case .ok: return "circle.fill"
        case .back: return "arrow.uturn.backward"
        case .home: return "house"
        case .channelUp: return "arrow.up.bin"
        case .channelDown: return "arrow.down.bin"
        case .playPause: return "playpause"
        case .stop: return "stop"
        case .next: return "forward.end"
        case .previous: return "backward.end"
        case .rewind: return "backward"
        case .fastForward: return "forward"
        }
    }
}
