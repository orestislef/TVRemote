import WidgetKit
import SwiftUI

// MARK: - Timeline Provider

struct TVRemoteTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TVRemoteEntry {
        TVRemoteEntry(date: .now, lastDeviceName: "Living Room TV", deviceCount: 1)
    }

    func getSnapshot(in context: Context, completion: @escaping (TVRemoteEntry) -> Void) {
        let entry = TVRemoteEntry(
            date: .now,
            lastDeviceName: loadLastDeviceName(),
            deviceCount: loadDeviceCount()
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TVRemoteEntry>) -> Void) {
        let entry = TVRemoteEntry(
            date: .now,
            lastDeviceName: loadLastDeviceName(),
            deviceCount: loadDeviceCount()
        )
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: .now)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadLastDeviceName() -> String? {
        guard let data = UserDefaults.standard.data(forKey: "watch_paired_devices"),
              let devices = try? JSONDecoder().decode([WidgetTVDevice].self, from: data),
              let first = devices.first else {
            return nil
        }
        return first.name.isEmpty ? first.host : first.name
    }

    private func loadDeviceCount() -> Int {
        guard let data = UserDefaults.standard.data(forKey: "watch_paired_devices"),
              let devices = try? JSONDecoder().decode([WidgetTVDevice].self, from: data) else {
            return 0
        }
        return devices.count
    }
}

/// Lightweight Codable struct for widget (avoids depending on main app's TVDevice)
private struct WidgetTVDevice: Codable {
    let name: String
    let host: String
}

// MARK: - Timeline Entry

struct TVRemoteEntry: TimelineEntry {
    let date: Date
    let lastDeviceName: String?
    let deviceCount: Int
}

// MARK: - Complication Views

struct TVRemoteComplicationView: View {
    @Environment(\.widgetFamily) var family
    let entry: TVRemoteEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryRectangular:
            rectangularView
        case .accessoryInline:
            inlineView
        case .accessoryCorner:
            cornerView
        default:
            circularView
        }
    }

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "av.remote.fill")
                .font(.title2)
                .foregroundStyle(.primary)
        }
    }

    private var rectangularView: some View {
        HStack(spacing: 8) {
            Image(systemName: "av.remote.fill")
                .font(.title3)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("TVRemote")
                    .font(.headline)
                    .widgetAccentable()
                if let name = entry.lastDeviceName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if entry.deviceCount > 0 {
                    Text("\(entry.deviceCount) TV\(entry.deviceCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No TVs paired")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var inlineView: some View {
        HStack(spacing: 4) {
            Image(systemName: "av.remote.fill")
            if let name = entry.lastDeviceName {
                Text(name)
            } else {
                Text("TVRemote")
            }
        }
    }

    private var cornerView: some View {
        Image(systemName: "av.remote.fill")
            .font(.title3)
            .widgetLabel {
                if let name = entry.lastDeviceName {
                    Text(name)
                } else {
                    Text("Remote")
                }
            }
    }
}

// MARK: - Widget

@main
struct TVRemoteWidget: Widget {
    let kind = "TVRemoteComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TVRemoteTimelineProvider()) { entry in
            TVRemoteComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("TV Remote")
        .description("Quick access to your TV remote control.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner,
        ])
    }
}
