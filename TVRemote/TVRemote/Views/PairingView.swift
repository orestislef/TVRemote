import SwiftUI

struct PairingView: View {
    let device: TVDevice
    @Environment(TVManager.self) private var tvManager
    @Environment(\.dismiss) private var dismiss
    @State private var pinCode = ""
    @State private var isPairing = false
    @State private var errorMessage: String?

    private var alreadyPaired: Bool {
        tvManager.pairedDevices.contains { $0.id == device.id }
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "tv")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text(device.displayName)
                .font(.title2.bold())

            Text(device.host)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if alreadyPaired {
                Label("Already Paired", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                    .padding()

                Button("Remove Pairing") {
                    tvManager.removePairedDevice(device)
                    dismiss()
                }
                .foregroundStyle(.red)
            } else {
                switch tvManager.pairing.state {
                case .idle, .connecting:
                    Button {
                        startPairing()
                    } label: {
                        HStack {
                            if tvManager.pairing.state == .connecting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(tvManager.pairing.state == .connecting ? "Connecting..." : "Start Pairing")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(tvManager.pairing.state == .connecting)

                case .waitingForCode:
                    VStack(spacing: 16) {
                        Text("Enter the hex code shown on your TV")
                            .font(.headline)

                        Text("Only characters 0-9 and A-F")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("Hex code (e.g. A1B2C3)", text: $pinCode)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3.monospaced())
                            .multilineTextAlignment(.center)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)

                        Button {
                            submitCode()
                        } label: {
                            Text("Submit")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pinCode.count < 4)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                case .verifying:
                    ProgressView("Verifying...")

                case .success:
                    Label("Paired Successfully!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                dismiss()
                            }
                        }

                case .failed:
                    VStack(spacing: 12) {
                        Label("Pairing Failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.title3)

                        if let msg = tvManager.pairing.errorMessage {
                            Text(msg).font(.caption).foregroundStyle(.secondary)
                        }

                        Button("Try Again") {
                            tvManager.pairing.cancel()
                            pinCode = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Pair TV")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // Cancel any in-progress pairing when navigating away
            if tvManager.pairing.state != .success {
                tvManager.pairing.cancel()
            }
            pinCode = ""
            errorMessage = nil
        }
    }

    private func startPairing() {
        errorMessage = nil
        Task {
            do {
                try await tvManager.startPairing(device: device)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func submitCode() {
        errorMessage = nil
        Task {
            do {
                try await tvManager.submitPairingCode(pinCode, device: device)
                PhoneSessionManager.shared.sendPairedDevicesToWatch()
                PhoneSessionManager.shared.sendCertificateToWatch()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
