import SwiftUI

struct PairingView: View {
    let device: TVDevice
    let isRepair: Bool
    @Environment(TVManager.self) private var tvManager
    @Environment(\.dismiss) private var dismiss
    @State private var pinCode = ""

    init(device: TVDevice, isRepair: Bool = false) {
        self.device = device
        self.isRepair = isRepair
    }

    /// Discovery ids change with the IP, so the paired record is matched by name too.
    private var pairedRecord: TVDevice? {
        tvManager.pairedRecord(matching: device)
    }

    /// Pairing adds the device before the success screen shows, so success wins here.
    private var showsAlreadyPaired: Bool {
        !isRepair && pairedRecord != nil && tvManager.pairing.state != .success
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

            if showsAlreadyPaired {
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
                if isRepair, tvManager.pairing.state == .idle {
                    Text("This TV no longer recognises your iPhone. Pair it again to keep using it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

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
                            Text(tvManager.pairing.state == .connecting ? "Connecting…" : "Start Pairing")
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

                        if let message = tvManager.pairing.errorMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

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
                    ProgressView("Verifying…")

                case .success:
                    Label("Paired Successfully!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                        .task {
                            try? await Task.sleep(for: .seconds(1.5))
                            guard !Task.isCancelled else { return }
                            dismiss()
                        }

                case .failed:
                    VStack(spacing: 12) {
                        Label("Pairing Failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.title3)

                        if let message = tvManager.pairing.errorMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        Button("Try Again") {
                            tvManager.pairing.cancel()
                            pinCode = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Spacer()
        }
        .padding()
        .navigationTitle(isRepair ? "Pair Again" : "Pair TV")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // A previous pairing can leave .success or .failed behind.
            tvManager.pairing.cancel()
            pinCode = ""
        }
        .onDisappear {
            tvManager.pairing.cancel()
            pinCode = ""
        }
    }

    /// Uses the latest address on file, which may be newer than the one we were opened with.
    private var pairingTarget: TVDevice {
        tvManager.pairedDevices.first { $0.id == device.id } ?? device
    }

    // Both report failures through pairing.state and pairing.errorMessage.
    private func startPairing() {
        Task {
            try? await tvManager.startPairing(device: pairingTarget)
        }
    }

    private func submitCode() {
        Task {
            guard (try? await tvManager.submitPairingCode(pinCode, device: pairingTarget)) != nil else { return }
            if isRepair {
                tvManager.retry()
            }
        }
    }
}
