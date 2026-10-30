import Foundation
import WatchKit

/// Own cases so that views don't each need to import WatchKit.
enum Haptic {
    case click, directionUp, directionDown
    case start, stop
    case success, notification, failure, retry

    private static var lastPlayedAt = Date.distantPast

    func play() {
        // AppStorage doesn't write its default, so a missing key means on.
        let isEnabled = UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
        guard isEnabled else { return }

        // The engine stalls for 100 ms if a new haptic interrupts one in progress.
        let now = Date()
        guard now.timeIntervalSince(Self.lastPlayedAt) >= 0.08 else { return }
        Self.lastPlayedAt = now
        WKInterfaceDevice.current().play(type)
    }

    private var type: WKHapticType {
        switch self {
        case .click: return .click
        case .directionUp: return .directionUp
        case .directionDown: return .directionDown
        case .start: return .start
        case .stop: return .stop
        case .success: return .success
        case .notification: return .notification
        case .failure: return .failure
        case .retry: return .retry
        }
    }
}
