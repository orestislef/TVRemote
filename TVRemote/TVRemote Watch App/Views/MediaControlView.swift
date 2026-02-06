import SwiftUI

struct MediaControlView: View {
    let onCommand: (RemoteCommand) -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Volume
            VStack(spacing: 4) {
                Text("Volume")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { onCommand(.volumeDown) } label: {
                        Image(systemName: "speaker.minus.fill")
                            .frame(width: 44, height: 34)
                    }
                    .buttonStyle(.bordered)

                    Button { onCommand(.mute) } label: {
                        Image(systemName: "speaker.slash.fill")
                            .frame(width: 40, height: 34)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    Button { onCommand(.volumeUp) } label: {
                        Image(systemName: "speaker.plus.fill")
                            .frame(width: 44, height: 34)
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Channel
            VStack(spacing: 4) {
                Text("Channel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { onCommand(.channelDown) } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.down")
                            Text("CH")
                        }
                        .font(.caption)
                        .frame(width: 56, height: 34)
                    }
                    .buttonStyle(.bordered)

                    Button { onCommand(.channelUp) } label: {
                        HStack(spacing: 2) {
                            Text("CH")
                            Image(systemName: "chevron.up")
                        }
                        .font(.caption)
                        .frame(width: 56, height: 34)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
