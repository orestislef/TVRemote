import SwiftUI

struct DPadView: View {
    let onCommand: (RemoteCommand) -> Void

    var body: some View {
        VStack(spacing: 6) {
            // Power button top-right
            HStack {
                Spacer()
                Button { onCommand(.power) } label: {
                    Image(systemName: "power")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .clipShape(Circle())
            }

            // D-Pad
            VStack(spacing: 2) {
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
            }

            // Back button
            Button { onCommand(.back) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Back")
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}
