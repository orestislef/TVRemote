import SwiftUI

struct RemoteView: View {
    let deviceName: String
    let onCommand: (RemoteCommand) -> Void
    let onDisconnect: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showMedia = false

    var body: some View {
        ScrollView {
            if showMedia {
                MediaControlView(onCommand: onCommand)
            } else {
                DPadView(onCommand: onCommand)
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
                .font(.caption2)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
        }
        .navigationTitle(deviceName)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    onDisconnect()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
