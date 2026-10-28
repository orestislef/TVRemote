import SwiftUI

/// Full remote control screen for the phone — one centered page:
/// status bar, D-Pad, media transport, volume (live TV state), and an
/// expandable "more" section. Centered symmetric layout that fits all
/// phone widths.
struct PhoneRemoteView: View {
    let device: TVDevice
    @Environment(TVManager.self) private var tvManager
    @State private var showMore = false

    private var connection: AndroidTVConnection {
        tvManager.remoteConnection
    }

    private var isConnected: Bool {
        connection.isConnected
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if isConnected {
                    statusBar
                    dPad
                    mediaControls
                    volumeControls
                    moreControls

                    Button {
                        tvManager.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 8)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "tv.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                        Button {
                            connectToDevice()
                        } label: {
                            Text("Connect")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(minHeight: 380)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !isConnected {
                connectToDevice()
            }
        }
    }

    // MARK: - Status (TV on/off, current app, mute)

    private var statusBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("TV On")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()

            Divider()
                .frame(height: 14)

            Image(systemName: "app.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(connection.currentApp.isEmpty ? "Home" : connection.currentApp)
                .font(.caption)
                .lineLimit(1)
                .layoutPriority(1)
                .minimumScaleFactor(0.75)

            if connection.volumeMuted {
                Spacer(minLength: 6)
                Image(systemName: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Muted")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - D-Pad

    private var dPad: some View {
        VStack(spacing: 12) {
            padButton(.up, icon: "chevron.up", width: 80, height: 56)

            HStack(spacing: 12) {
                padButton(.left, icon: "chevron.left", width: 60, height: 60)
                Button { tvManager.sendCommand(.ok) } label: {
                    Text("OK")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Color.blue))
                }
                .buttonStyle(.plain)
                padButton(.right, icon: "chevron.right", width: 60, height: 60)
            }

            padButton(.down, icon: "chevron.down", width: 80, height: 56)
        }
    }

    // MARK: - Media

    private var mediaControls: some View {
        VStack(spacing: 10) {
            Label("Media", systemImage: "play.rectangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Total ≈ 4×56 + 66 + spacing = 356 — fits the narrowest
            // iPhone (375pt) with content area 327 if padded 24 each side.
            // Use spacing 6 to be safe on SE-sized screens too.
            HStack(spacing: 6) {
                transportButton(.previous, icon: "backward.end.fill")
                transportButton(.rewind, icon: "backward.fill")
                transportButton(.playPause, icon: "playpause.fill", tint: .green, prominent: true)
                transportButton(.fastForward, icon: "forward.fill")
                transportButton(.next, icon: "forward.end.fill")
            }
        }
    }

    // MARK: - Volume (live TV-reported level)

    private var volumeControls: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Volume", systemImage: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(connection.volumeMuted ? "Muted" : "\(connection.volumeLevel) / \(connection.volumeMax)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(connection.volumeMuted ? .orange : .secondary)
            }

            HStack(spacing: 12) {
                transportButton(.volumeDown, icon: "speaker.minus.fill", prominent: true)
                transportButton(.mute, icon: "speaker.slash.fill", tint: connection.volumeMuted ? .orange : .secondary)
                transportButton(.volumeUp, icon: "speaker.plus.fill", prominent: true)
            }

            // Progress bar showing the live TV-reported level
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(volumeMuted ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                        .frame(width: volumeWidth(in: geo.size.width))
                }
            }
            .frame(height: 6)
            .animation(.snappy, value: connection.volumeLevel)
            .animation(.snappy, value: connection.volumeMuted)
        }
    }

    private var volumeMuted: Bool { connection.volumeMuted }

    private func volumeWidth(in width: CGFloat) -> CGFloat {
        guard connection.volumeMax > 0 else { return 0 }
        let fraction = CGFloat(connection.volumeLevel) / CGFloat(connection.volumeMax)
        return max(6, width * fraction)
    }

    // MARK: - More

    private var moreControls: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation { showMore.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showMore ? "chevron.up" : "ellipsis.circle")
                    Text(showMore ? "Less" : "More")
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)

            if showMore {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        transportButton(.channelDown, icon: "chevron.down.circle")
                        transportButton(.channelUp, icon: "chevron.up.circle")
                    }

                    HStack(spacing: 12) {
                        padButton(.back, icon: "arrow.uturn.backward", width: 60, height: 46)
                        padButton(.home, icon: "house.fill", width: 60, height: 46)
                        padButton(.power, icon: "power", width: 60, height: 46, tint: .red)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func padButton(_ cmd: RemoteCommand, icon: String, width: CGFloat, height: CGFloat, tint: Color = .blue) -> some View {
        Button { tvManager.sendCommand(cmd) } label: {
            Image(systemName: icon)
                .font(.title2.bold())
                .foregroundStyle(tint)
                .frame(width: width, height: height)
                .background(Capsule().fill(Color(.systemGray5)))
        }
        .buttonStyle(.plain)
    }

    private func transportButton(_ cmd: RemoteCommand, icon: String, tint: Color = .blue, prominent: Bool = false) -> some View {
        Button { tvManager.sendCommand(cmd) } label: {
            Image(systemName: icon)
                .font(.title3.bold())
                .foregroundStyle(prominent ? .white : Color(tint))
                .frame(width: prominent ? 66 : 56, height: 50)
                .background(Capsule().fill(prominent ? tint : Color(.systemGray5)))
        }
        .buttonStyle(.plain)
    }

    private func connectToDevice() {
        Task {
            try? await tvManager.connectToDevice(device)
        }
    }
}
