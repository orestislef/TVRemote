import SwiftUI

/// Full remote control screen for the phone — mirrors the Watch app's
/// D-Pad + media controls layout.
struct PhoneRemoteView: View {
    let device: TVDevice
    @Environment(TVManager.self) private var tvManager
    @State private var showMedia = false

    private var isConnected: Bool {
        tvManager.remoteConnection.isConnected
    }

    var body: some View {
        VStack(spacing: 20) {
            if isConnected {
                Spacer(minLength: 8)

                if showMedia {
                    mediaControls
                } else {
                    dPad
                }

                // Toggle
                Button {
                    withAnimation {
                        showMedia.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showMedia ? "dpad.fill" : "slider.horizontal.3")
                        Text(showMedia ? "D-Pad" : "Media")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.blue)

                Button {
                    tvManager.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 8)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "tv.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Not connected")
                        .foregroundStyle(.secondary)
                    Button {
                        connect()
                    } label: {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !isConnected {
                connect()
            }
        }
    }

    // MARK: - D-Pad

    private var dPad: some View {
        VStack(spacing: 12) {
            padButton(.up, icon: "chevron.up", width: 76, height: 56)

            HStack(spacing: 10) {
                padButton(.left, icon: "chevron.left", width: 56, height: 56)
                Button { tvManager.sendCommand(.ok) } label: {
                    Text("OK")
                        .font(.headline.bold())
                        .frame(width: 68, height: 68)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                padButton(.right, icon: "chevron.right", width: 56, height: 56)
            }

            padButton(.down, icon: "chevron.down", width: 76, height: 56)

            HStack(spacing: 8) {
                padButton(.back, icon: "arrow.uturn.backward", width: 56, height: 46)
                padButton(.home, icon: "house.fill", width: 56, height: 46)
                padButton(.power, icon: "power", width: 56, height: 46, tint: .red)
            }
        }
    }

    // MARK: - Media controls

    private var mediaControls: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Label("Volume", systemImage: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    mediaButton(.volumeDown, icon: "speaker.minus.fill", tint: .blue)
                    mediaButton(.mute, icon: "speaker.slash.fill", tint: .orange)
                    mediaButton(.volumeUp, icon: "speaker.plus.fill", tint: .blue)
                }
            }

            VStack(spacing: 8) {
                Label("Channel", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    mediaButton(.channelDown, icon: "chevron.down.circle", tint: .blue)
                    mediaButton(.channelUp, icon: "chevron.up.circle", tint: .blue)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func padButton(_ cmd: RemoteCommand, icon: String, width: CGFloat, height: CGFloat, tint: Color = .blue) -> some View {
        Button { tvManager.sendCommand(cmd) } label: {
            Image(systemName: icon)
                .font(.title2.bold())
                .frame(width: width, height: height)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    private func mediaButton(_ cmd: RemoteCommand, icon: String, tint: Color) -> some View {
        Button { tvManager.sendCommand(cmd) } label: {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 76, height: 62)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    private func connect() {
        Task {
            try? await tvManager.connectToDevice(device)
        }
    }
}
