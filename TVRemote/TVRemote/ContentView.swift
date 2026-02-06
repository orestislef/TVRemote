import SwiftUI

struct ContentView: View {
    @Environment(TVManager.self) private var tvManager
    @State private var watchSession = PhoneSessionManager.shared

    var body: some View {
        TabView {
            Tab("My TVs", systemImage: "tv.fill") {
                NavigationStack {
                    PairedTVsView()
                }
            }

            Tab("Discover", systemImage: "wifi") {
                NavigationStack {
                    DiscoveryView()
                }
            }

            Tab("Watch", systemImage: "applewatch") {
                NavigationStack {
                    WatchStatusView()
                }
            }
        }
    }
}

// MARK: - Watch Status View

struct WatchStatusView: View {
    @State private var session = PhoneSessionManager.shared

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: watchIcon)
                        .font(.system(size: 40))
                        .foregroundStyle(iconColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle)
                            .font(.headline)
                        Text(statusSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            if !session.isPaired {
                Section {
                    Label {
                        Text("Pair an Apple Watch with your iPhone in the Apple Watch app, then come back here.")
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                    }
                    Button {
                        session.openWatchAppSettings()
                    } label: {
                        Label("Open Apple Watch App", systemImage: "applewatch")
                    }
                }
            } else if !session.isWatchAppInstalled {
                Section {
                    Label {
                        Text("The TVRemote Watch app is not installed. Install it from the Apple Watch app on your iPhone.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Button {
                        session.openWatchAppSettings()
                    } label: {
                        Label("Install Watch App", systemImage: "arrow.down.circle")
                    }
                }
            } else {
                Section {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Watch App Installed")
                            Text(session.isReachable ? "Watch is reachable" : "Watch is not reachable right now")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    if session.isReachable {
                        Button("Sync TVs to Watch") {
                            session.sendPairedDevicesToWatch()
                        }
                    }
                }
            }
        }
        .navigationTitle("Apple Watch")
        .onAppear {
            session.refreshStatus()
        }
    }

    private var watchIcon: String {
        if !session.isPaired { return "applewatch.slash" }
        if !session.isWatchAppInstalled { return "applewatch.and.arrow.forward" }
        return session.isReachable ? "applewatch.radiowaves.left.and.right" : "applewatch"
    }

    private var iconColor: Color {
        if !session.isPaired { return .secondary }
        if !session.isWatchAppInstalled { return .orange }
        return session.isReachable ? .green : .blue
    }

    private var statusTitle: String {
        if !session.isPaired { return "No Apple Watch" }
        if !session.isWatchAppInstalled { return "Watch App Not Installed" }
        return "Watch App Ready"
    }

    private var statusSubtitle: String {
        if !session.isPaired { return "Pair an Apple Watch to use the remote from your wrist." }
        if !session.isWatchAppInstalled { return "Tap below to install the TVRemote Watch app." }
        return session.isReachable ? "Connected and ready to control your TV." : "Open the Watch app to start controlling."
    }
}
