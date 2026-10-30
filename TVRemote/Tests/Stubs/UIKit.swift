// Signatures from developer.apple.com/documentation/uikit/uiapplication. Plus fake controls.
import Foundation

public struct UIBackgroundTaskIdentifier: RawRepresentable, Hashable, Sendable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let invalid = UIBackgroundTaskIdentifier(rawValue: 0)
}

@MainActor
open class UIApplication {
    public static let shared = UIApplication()
    public struct OpenExternalURLOptionsKey: Hashable, Sendable { public let rawValue: String }

    nonisolated(unsafe) public var fakeTasks: [Int: (@MainActor @Sendable () -> Void)?] = [:]
    nonisolated(unsafe) public var fakeNext = 1
    nonisolated(unsafe) public var fakeEndedCount = 0

    nonisolated public func beginBackgroundTask(withName taskName: String?, expirationHandler handler: (@MainActor @Sendable () -> Void)? = nil) -> UIBackgroundTaskIdentifier {
        let id = fakeNext
        fakeNext += 1
        fakeTasks[id] = handler
        return UIBackgroundTaskIdentifier(rawValue: id)
    }
    nonisolated public func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        fakeEndedCount += 1
        fakeTasks[identifier.rawValue] = nil
    }
    public func open(_ url: URL, options: [OpenExternalURLOptionsKey: Any] = [:], completionHandler completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {}
}
