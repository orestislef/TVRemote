import SwiftUI

struct RemoteView: View {
    let deviceName: String
    let onCommand: (RemoteCommand) -> Void
    let onDisconnect: () -> Void

    @State private var showMediaControls = false

    var body: some View {
        TabView {
            ScrollView {
                DPadView(onCommand: onCommand)
            }

            ScrollView {
                MediaControlView(onCommand: onCommand)
            }
        }
        .tabViewStyle(.verticalPage)
        .navigationTitle(deviceName)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    onDisconnect()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
