import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager.shared
    /// Follows session.activeDevice, but going back only clears this: the session
    /// stays up and its row says so. A separate value also keeps the system back
    /// button from having to mean disconnect.
    @State private var presented: TVDevice?
    @State private var didRestore = false
    @State private var isStillLooking = true
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        NavigationStack {
            // Not a Group: its modifiers can bind per branch, and these must outlive a swap.
            ZStack {
                if !session.pairedDevices.isEmpty {
                    deviceList
                } else if isStillLooking {
                    lookingState
                } else if !session.isPhoneReachable {
                    emptyState(
                        symbol: "iphone.slash",
                        title: "Open TVRemote on your iPhone",
                        message: "Your TVs sync from there."
                    )
                } else {
                    emptyState(
                        symbol: "tv.slash",
                        title: "No TVs Yet",
                        message: "Pair one in TVRemote on your iPhone."
                    )
                }
            }
            .navigationTitle("My TVs")
            .navigationDestination(item: $presented) { _ in
                RemoteView(session: session)
            }
            .onAppear {
                session.requestDevices()
                // Only the first time, or going back would push the remote again.
                guard !didRestore else { return }
                didRestore = true
                presented = session.activeDevice
            }
            .onChange(of: session.activeDevice?.id) { _, id in
                presented = id == nil ? nil : session.activeDevice
            }
            // Reachability starts false until WCSession activates, and once it turns
            // true the list is still one reply away, so each change gets its own wait.
            .task(id: session.isPhoneReachable) {
                isStillLooking = true
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                isStillLooking = false
            }
        }
    }

    // MARK: - List

    private var deviceList: some View {
        List {
            Section {
                ForEach(session.pairedDevices) { device in
                    Button {
                        select(device)
                    } label: {
                        row(for: device)
                    }
                    .swipeActions(edge: .trailing) {
                        if session.activeDevice?.id == device.id {
                            Button("Disconnect", role: .destructive) {
                                session.disconnect()
                            }
                        }
                    }
                }
            }
            Section {
                Toggle("Haptics", isOn: $hapticsEnabled)
            }
        }
    }

    private func select(_ device: TVDevice) {
        session.connect(to: device)
        if session.activeDevice?.id == device.id {
            presented = session.activeDevice
        }
    }

    private func row(for device: TVDevice) -> some View {
        let state = rowState(for: device)
        return HStack(spacing: 8) {
            Image(systemName: "tv.fill")
                .foregroundStyle(state.isConnected ? RemoteTheme.green : RemoteTheme.phosphor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if state.isConnected {
                        Circle()
                            .fill(RemoteTheme.green)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    if state.isBusy && !isLuminanceReduced {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 14, height: 14)
                    }
                    Text(state.text)
                        .font(.caption2)
                        .foregroundStyle(state.color)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private struct RowState {
        let text: String
        var color = RemoteTheme.secondary
        var isConnected = false
        var isBusy = false
    }

    private func rowState(for device: TVDevice) -> RowState {
        if session.activeDevice?.id == device.id {
            switch session.status.phase {
            case .connected:
                if session.status.isTVOff {
                    return RowState(text: "TV is off", color: RemoteTheme.ember)
                }
                return RowState(text: "Connected", isConnected: true)
            case .connecting:
                return RowState(text: "Connecting…", isBusy: true)
            case .reconnecting:
                return RowState(text: "Reconnecting…", color: RemoteTheme.amber, isBusy: true)
            case .failed:
                return RowState(text: "Can't reach", color: RemoteTheme.ember)
            case .idle:
                break
            }
        }
        if session.isPhoneReachable {
            return RowState(text: "Ready via iPhone")
        }
        // A real Watch can't open a socket to the TV (TN3135), so a certificate only
        // promises anything in the simulator.
        #if targetEnvironment(simulator)
        if session.hasCertificate {
            return RowState(text: "Ready")
        }
        #endif
        return RowState(text: "Can't reach", color: RemoteTheme.ember)
    }

    // MARK: - Empty states

    private var lookingState: some View {
        VStack(spacing: 8) {
            if !isLuminanceReduced {
                ProgressView()
            }
            Text("Looking for TVs…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func emptyState(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
