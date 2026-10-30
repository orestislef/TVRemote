import SwiftUI

struct PairedTVsView: View {
    @Environment(TVManager.self) private var tvManager
    var onFindTVs: () -> Void = {}

    var body: some View {
        List {
            if tvManager.pairedDevices.isEmpty {
                ContentUnavailableView {
                    Label("No TVs Yet", systemImage: "tv.slash")
                } description: {
                    Text("Find your Android TV on this Wi-Fi and pair it.")
                } actions: {
                    Button("Find TVs", action: onFindTVs)
                        .buttonStyle(.borderedProminent)
                }
            }

            ForEach(tvManager.pairedDevices) { device in
                NavigationLink {
                    PhoneRemoteView(device: device)
                } label: {
                    PairedTVRow(device: device)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        tvManager.removePairedDevice(device)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("My TVs")
    }
}

// MARK: - Row

private struct PairedTVRow: View {
    let device: TVDevice

    @Environment(TVManager.self) private var tvManager
    @State private var debouncer = PhaseDebouncer()

    private var phase: ConnectionPhase {
        tvManager.phase(for: device)
    }

    private var shownPhase: ConnectionPhase {
        phase.isConnected ? phase : debouncer.shown ?? .idle
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tv.fill")
                .font(.title3)
                .foregroundStyle(shownPhase.isConnected ? Color.green : Color.blue)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.headline)
                stateLine
                    .font(.subheadline)
            }
        }
        .frame(minHeight: 72)
        .accessibilityElement(children: .combine)
        .onAppear {
            debouncer.show(phase)
        }
        .onDisappear {
            debouncer.cancel()
        }
        .onChange(of: phase) { _, new in
            debouncer.update(to: new)
        }
    }

    @ViewBuilder
    private var stateLine: some View {
        switch shownPhase {
        case .connected:
            if tvManager.status.isTVOff {
                Text("TV is off")
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(connectedText)
                        .foregroundStyle(.secondary)
                }
            }
        case .connecting:
            Text("Connecting…")
                .foregroundStyle(.secondary)
        case .reconnecting:
            Text("Reconnecting…")
                .foregroundStyle(.orange)
        case .failed:
            Text("Can't reach")
                .foregroundStyle(.red)
        case .idle:
            Text(device.host)
                .foregroundStyle(.secondary)
        }
    }

    private var connectedText: String {
        guard let app = tvManager.status.appName else { return "Connected" }
        return "Connected · \(app)"
    }
}
