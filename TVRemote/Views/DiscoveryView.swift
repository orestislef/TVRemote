import SwiftUI

struct DiscoveryView: View {
    @Environment(TVManager.self) private var tvManager

    var body: some View {
        List {
            Section {
                if tvManager.discovery.isSearching {
                    HStack {
                        ProgressView()
                        Text("Searching for Android TVs...")
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

                            if tvManager.pairedDevices.contains(where: { $0.id == device.id }) {
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
            tvManager.discovery.startDiscovery()
        }
        .onDisappear {
            tvManager.discovery.stopDiscovery()
        }
    }
}
