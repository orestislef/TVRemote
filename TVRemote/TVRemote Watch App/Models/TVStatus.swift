import Foundation

// Keep this file identical in the iPhone and Watch targets. The wire format
// below is what the iPhone relays to the Watch over WatchConnectivity.

/// How commands reach the TV.
enum ConnectionRoute: String, Codable, Sendable {
    case direct
    case viaPhone
}

/// Why a connection gave up. Copy is shared by both apps.
enum ConnectionFailure: String, Codable, Sendable {
    case tvUnreachable
    case phoneUnreachable
    case needsPairing
    case noWiFi
    case localNetworkDenied
    case timeout

    var title: String {
        switch self {
        case .tvUnreachable: return "Can't Reach TV"
        case .phoneUnreachable: return "Can't Reach iPhone"
        case .needsPairing: return "Pair This TV Again"
        case .noWiFi: return "No Wi-Fi"
        case .localNetworkDenied: return "Local Network Is Off"
        case .timeout: return "TV Didn't Respond"
        }
    }

    var message: String {
        switch self {
        case .tvUnreachable: return "Check it's on and on this Wi-Fi."
        case .phoneUnreachable: return "Open TVRemote on your iPhone."
        case .needsPairing: return "Use TVRemote on your iPhone."
        case .noWiFi: return "Connect, then try again."
        case .localNetworkDenied: return "Allow Local Network for TVRemote in Settings."
        case .timeout: return "It may be asleep or off."
        }
    }

    var symbol: String {
        switch self {
        case .tvUnreachable: return "tv.slash"
        case .phoneUnreachable: return "iphone.slash"
        case .needsPairing: return "link.badge.plus"
        case .noWiFi: return "wifi.slash"
        case .localNetworkDenied: return "network.slash"
        case .timeout: return "hourglass"
        }
    }
}

enum ConnectionPhase: Equatable, Sendable {
    case idle
    case connecting
    case connected(ConnectionRoute)
    case reconnecting
    case failed(ConnectionFailure)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusy: Bool {
        self == .connecting || self == .reconnecting
    }

    var failure: ConnectionFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

/// Backoff used after a session drops. Bounded so two clients on the same
/// certificate can't fight over the TV forever.
enum ReconnectPolicy {
    static let delays: [Double] = [1, 2, 4, 8, 8]
    /// A session must live this long before the retry budget resets.
    static let stableSessionSeconds: Double = 30
    /// No traffic for this long means the peer is gone. The TV pings about every 5s.
    static let silenceTimeoutSeconds: Double = 16
}

/// Everything the UI needs to know about the TV, whichever route is in use.
struct TVStatus: Equatable, Sendable {
    var phase: ConnectionPhase = .idle
    var deviceId: String?
    /// Nil until the TV reports it. Kept through a reconnect so the UI can dim it.
    var volumeLevel: Int?
    var volumeMax: Int?
    var isMuted = false
    /// Nil until the TV sends remote_start.
    var isOn: Bool?
    var appLabel = ""
    var appPackage = ""

    /// True while the socket is up but the TV reports standby.
    var isTVOff: Bool {
        phase.isConnected && isOn == false
    }

    /// Fraction for gauges, clamped. Nil when the TV gives no usable range.
    var volumeFraction: Double? {
        guard let level = volumeLevel, let max = volumeMax, max > 0 else { return nil }
        return Swift.min(1, Swift.max(0, Double(level) / Double(max)))
    }

    /// Name to show for the foreground app, or nil if the TV hasn't said yet.
    var appName: String? {
        if !appLabel.isEmpty { return appLabel }
        guard !appPackage.isEmpty else { return nil }
        return Self.friendlyName(forPackage: appPackage)
    }

    static func friendlyName(forPackage package: String) -> String {
        let known: [String: String] = [
            "com.netflix.ninja": "Netflix",
            "com.netflix.mediaclient": "Netflix",
            "com.google.android.youtube.tv": "YouTube",
            "com.google.android.youtube.tvkids": "YouTube Kids",
            "com.google.android.youtube.tvmusic": "YouTube Music",
            "com.amazon.amazonvideo.livingroom": "Prime Video",
            "com.disney.disneyplus": "Disney+",
            "com.wbd.stream": "Max",
            "com.hbo.hbonow": "Max",
            "com.spotify.tv.android": "Spotify",
            "com.plexapp.android": "Plex",
            "tv.twitch.android.app": "Twitch",
            "com.apple.atve.androidtv.appletv": "Apple TV",
            "com.google.android.tvlauncher": "Home",
            "com.google.android.apps.tv.launcherx": "Home",
            "com.google.android.leanbacklauncher": "Home",
            "com.android.tv.settings": "Settings",
        ]
        if let name = known[package] { return name }
        let last = package.split(separator: ".").last.map(String.init) ?? package
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    // MARK: - WatchConnectivity wire format

    /// Plist-safe dictionary. Only property-list types go over WatchConnectivity.
    var wirePayload: [String: Any] {
        var payload: [String: Any] = [
            "phase": phase.wireName,
            "muted": isMuted,
            "appLabel": appLabel,
            "appPackage": appPackage,
        ]
        if case .failed(let failure) = phase { payload["failure"] = failure.rawValue }
        if let deviceId { payload["deviceId"] = deviceId }
        if let volumeLevel { payload["level"] = volumeLevel }
        if let volumeMax { payload["max"] = volumeMax }
        if let isOn { payload["isOn"] = isOn }
        return payload
    }

    /// Reads a status sent by the iPhone. A connected phone is `.viaPhone` from
    /// the Watch's point of view.
    init?(wire payload: [String: Any]) {
        guard let phaseName = payload["phase"] as? String else { return nil }
        switch phaseName {
        case "idle": phase = .idle
        case "connecting": phase = .connecting
        case "connected": phase = .connected(.viaPhone)
        case "reconnecting": phase = .reconnecting
        case "failed":
            let failure = (payload["failure"] as? String).flatMap(ConnectionFailure.init(rawValue:))
            phase = .failed(failure ?? .tvUnreachable)
        default: return nil
        }
        deviceId = payload["deviceId"] as? String
        volumeLevel = payload["level"] as? Int
        volumeMax = payload["max"] as? Int
        isMuted = payload["muted"] as? Bool ?? false
        isOn = payload["isOn"] as? Bool
        appLabel = payload["appLabel"] as? String ?? ""
        appPackage = payload["appPackage"] as? String ?? ""
    }

    init() {}
}

extension ConnectionPhase {
    fileprivate var wireName: String {
        switch self {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reconnecting: return "reconnecting"
        case .failed: return "failed"
        }
    }
}
