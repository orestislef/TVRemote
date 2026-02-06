import SwiftUI

struct DPadView: View {
    let onCommand: (RemoteCommand) -> Void

    var body: some View {
        VStack(spacing: 2) {
            // D-Pad
            Button { onCommand(.up) } label: {
                Image(systemName: "chevron.up")
                    .font(.title3.bold())
                    .frame(width: 50, height: 32)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 2) {
                Button { onCommand(.left) } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.bold())
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)

                Button { onCommand(.ok) } label: {
                    Text("OK")
                        .font(.headline.bold())
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())

                Button { onCommand(.right) } label: {
                    Image(systemName: "chevron.right")
                        .font(.title3.bold())
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
            }

            Button { onCommand(.down) } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.bold())
                    .frame(width: 50, height: 32)
            }
            .buttonStyle(.bordered)

            // Back / Home / Power
            HStack(spacing: 4) {
                Button { onCommand(.back) } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 36, height: 28)
                }
                .buttonStyle(.bordered)

                Button { onCommand(.home) } label: {
                    Image(systemName: "house.fill")
                        .frame(width: 36, height: 28)
                }
                .buttonStyle(.bordered)

                Button { onCommand(.power) } label: {
                    Image(systemName: "power")
                        .frame(width: 36, height: 28)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .font(.caption)
        }
    }
}
