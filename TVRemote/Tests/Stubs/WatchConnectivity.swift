// Signatures from developer.apple.com/documentation/watchconnectivity. STUB_WATCHOS picks
// the watchOS availability: isPaired and friends are iOS only. Plus fake controls.
import Foundation

public enum WCSessionActivationState: Int, Sendable { case notActivated = 0, inactive = 1, activated = 2 }

public let WCErrorDomain = "WCErrorDomain"
public struct WCError: Error, Hashable, Sendable {
    public enum Code: Int, Sendable {
        case genericError = 7001, sessionNotSupported = 7002, sessionMissingDelegate = 7003, sessionNotActivated = 7004
        case deviceNotPaired = 7005, watchAppNotInstalled = 7006, notReachable = 7007, invalidParameter = 7008
        case payloadTooLarge = 7009, payloadUnsupportedTypes = 7010, messageReplyFailed = 7011, messageReplyTimedOut = 7012
        case fileAccessDenied = 7013, deliveryFailed = 7014, insufficientSpace = 7015, sessionInactive = 7016
        case transferTimedOut = 7017, companionAppNotInstalled = 7018, watchOnlyApp = 7019
    }
    public let code: Code
    public init(_ code: Code) { self.code = code }
}

public protocol WCSessionDelegate: NSObjectProtocol {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?)
#if !STUB_WATCHOS
    func sessionDidBecomeInactive(_ session: WCSession)
    func sessionDidDeactivate(_ session: WCSession)
    func sessionWatchStateDidChange(_ session: WCSession)
#endif
    func sessionReachabilityDidChange(_ session: WCSession)
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any])
    func session(_ session: WCSession, didReceiveMessage message: [String: Any])
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void)
}
// Stand-ins for @objc optional.
public extension WCSessionDelegate {
#if !STUB_WATCHOS
    func sessionWatchStateDidChange(_ session: WCSession) {}
#endif
    func sessionReachabilityDidChange(_ session: WCSession) {}
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {}
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {}
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {}
}

/// One outgoing sendMessage, held until the test answers it.
public final class FakeOutgoing: @unchecked Sendable {
    public let message: [String: Any]
    public let replyHandler: (([String: Any]) -> Void)?
    public let errorHandler: ((any Error) -> Void)?
    public private(set) var answered = false
    init(_ m: [String: Any], _ r: (([String: Any]) -> Void)?, _ e: ((any Error) -> Void)?) { message = m; replyHandler = r; errorHandler = e }
    public var action: String { message["action"] as? String ?? "" }
    /// Delivered on a background queue, as the real framework does.
    public func reply(_ payload: [String: Any]) {
        answered = true
        nonisolated(unsafe) let p = payload
        nonisolated(unsafe) let h = replyHandler
        DispatchQueue.global().async { h?(p) }
    }
    public func fail(_ error: any Error) {
        answered = true
        nonisolated(unsafe) let h = errorHandler
        DispatchQueue.global().async { h?(error) }
    }
}

open class WCSession: NSObject, @unchecked Sendable {
    nonisolated(unsafe) private static let shared = WCSession()
    public class var `default`: WCSession { shared }
    public class func isSupported() -> Bool { fakeSupported }
    nonisolated(unsafe) public static var fakeSupported = true

    public weak var delegate: (any WCSessionDelegate)?
    public private(set) var activationState: WCSessionActivationState = .notActivated
    public private(set) var isReachable = false
    public private(set) var applicationContext: [String: Any] = [:]
    public private(set) var receivedApplicationContext: [String: Any] = [:]
#if !STUB_WATCHOS
    public private(set) var isPaired = true
    public private(set) var isWatchAppInstalled = true
    public var isComplicationEnabled: Bool { false }
#else
    public var isCompanionAppInstalled: Bool { true }
#endif

    public func activate() { fakeActivateCount += 1 }
    public func updateApplicationContext(_ applicationContext: [String: Any]) throws {
        self.applicationContext = applicationContext
        fakeContextUpdates += 1
    }
    public func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?, errorHandler: ((any Error) -> Void)? = nil) {
        precondition(activationState == .activated, "sendMessage on an inactive session is a programmer error")
        let out = FakeOutgoing(message, replyHandler, errorHandler)
        fakeOutbox.append(out)
        if !isReachable { out.fail(WCError(.notReachable)) }
        else { fakeAutoAnswer?(out) }
    }

    // MARK: fake controls
    public var fakeActivateCount = 0
    public var fakeContextUpdates = 0
    public var fakeOutbox: [FakeOutgoing] = []
    /// Answers messages as they are sent, like a scripted counterpart.
    public var fakeAutoAnswer: ((FakeOutgoing) -> Void)?
    public func fakeReset() {
        fakeOutbox = []; fakeAutoAnswer = nil; fakeContextUpdates = 0
        applicationContext = [:]; receivedApplicationContext = [:]
        activationState = .activated; isReachable = false
    }
    public func fakeSetActivation(_ state: WCSessionActivationState) { activationState = state }
    public func fakeSetReachable(_ reachable: Bool, notify: Bool = true) {
        isReachable = reachable
        guard notify else { return }
        let session = self
        DispatchQueue.global().async { session.delegate?.sessionReachabilityDidChange(session) }
    }
    public func fakeSetReceivedContext(_ context: [String: Any]) { receivedApplicationContext = context }
    /// An incoming message from the counterpart, on a background queue.
    public func fakeIncoming(_ message: [String: Any], reply: (([String: Any]) -> Void)?) {
        let session = self
        nonisolated(unsafe) let m = message
        nonisolated(unsafe) let r = reply
        DispatchQueue.global().async {
            if let r { session.delegate?.session(session, didReceiveMessage: m, replyHandler: r) }
            else { session.delegate?.session(session, didReceiveMessage: m) }
        }
    }
    public func fakeIncomingContext(_ context: [String: Any]) {
        let session = self
        nonisolated(unsafe) let c = context
        DispatchQueue.global().async { session.delegate?.session(session, didReceiveApplicationContext: c) }
    }
    public func fakeFinishActivation(_ state: WCSessionActivationState = .activated) {
        activationState = state
        let session = self
        DispatchQueue.global().async { session.delegate?.session(session, activationDidCompleteWith: state, error: nil) }
    }
}
