import SwiftUI

struct DiscoveryView: View {
    @Environment(TVManager.self) private var tvManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        List {
            Section {
                if tvManager.discovery.isSearching {
                    HStack {
                        ProgressView()
                        Text("Searching for Android TVs…")
                            .foregroundStyle(.secondary)
                    }
                }

                if tvManager.discovery.discoveredDevices.isEmpty && !tvManager.discovery.isSearching {
                    ContentUnavailableView(
                        "No TVs Found",
                        systemImage: "tv",
                        description: Text("Make sure your Android TV is on and connected to the same WiFi network.")
                    )
                }

                ForEach(tvManager.discovery.discoveredDevices) { device in
                    NavigationLink(value: device) {
                        HStack {
                            Image(systemName: "tv")
                                .font(.title2)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading) {
                                Text(device.displayName)
                                    .font(.headline)
                                Text(device.host)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if tvManager.pairedRecord(matching: device) != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Discover TVs")
        .navigationDestination(for: TVDevice.self) { device in
            PairingView(device: device)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if tvManager.discovery.isSearching {
                        tvManager.discovery.stopDiscovery()
                    } else {
                        tvManager.discovery.startDiscovery()
                    }
                } label: {
                    Image(systemName: tvManager.discovery.isSearching ? "stop.circle" : "arrow.clockwise")
                }
            }
        }
        .onAppear {
            isVisible = true
            tvManager.discovery.startDiscovery()
        }
        .onDisappear {
            isVisible = false
            tvManager.discovery.stopDiscovery()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Backgrounding stops the search, and onAppear doesn't fire again on return.
            if newPhase == .active, isVisible {
                tvManager.discovery.startDiscovery()
            }
        }
    }
}
