// Declarations follow developer.apple.com/documentation/network, including the
// @preconcurrency @Sendable handler types. The class bodies are a fake that a test
// drives by hand. Callbacks arrive on the queue given to start(queue:), as in the real thing.
import Foundation
import Security

public struct NWInterface: Hashable, Sendable {
    public enum InterfaceType: Hashable, Sendable { case other, wifi, cellular, wiredEthernet, loopback }
    public let name: String
    public let type: InterfaceType
}

public enum NWEndpoint: Hashable, Sendable {
    public enum Host: Hashable, Sendable, ExpressibleByStringLiteral, CustomDebugStringConvertible {
        case name(String, NWInterface?)
        public init(_ string: String) { self = .name(string, nil) }
        public init(stringLiteral value: String) { self = .name(value, nil) }
        public var debugDescription: String { if case .name(let n, _) = self { return n }; return "" }
    }
    public struct Port: Hashable, Sendable, RawRepresentable, ExpressibleByIntegerLiteral {
        public var rawValue: UInt16
        public init?(rawValue: UInt16) { self.rawValue = rawValue }
        public init(integerLiteral value: UInt16) { rawValue = value }
    }
    case hostPort(host: Host, port: Port)
    case service(name: String, type: String, domain: String, interface: NWInterface?)
    case unix(path: String)
    case url(URL)
    case opaque(String)
}

public typealias DNSServiceErrorType = Int32

public enum NWError: Error, CustomDebugStringConvertible, LocalizedError, Equatable, Sendable {
    case posix(POSIXErrorCode)
    case dns(DNSServiceErrorType)
    case tls(OSStatus)
    case wifiAware(Int32)
    public var debugDescription: String {
        switch self {
        case .posix(let code): return "POSIXErrorCode: \(code.rawValue)"
        case .dns(let code): return "dns \(code)"
        case .tls(let code): return "tls \(code)"
        case .wifiAware(let code): return "wifiAware \(code)"
        }
    }
    public var errorDescription: String? { debugDescription }
}

public final class NWProtocolTCP {
    public final class Options: @unchecked Sendable {
        public init() {}
        public var noDelay = false
        public var enableKeepalive = false
        public var keepaliveIdle = 0
        public var keepaliveCount = 0
        public var keepaliveInterval = 0
        public var connectionTimeout = 0
        public var connectionDropTime = 0
    }
}
public final class NWProtocolTLS {
    public final class Options: @unchecked Sendable {
        public init() {}
        public var securityProtocolOptions: sec_protocol_options_t { _options }
        private let _options = sec_protocol_options_t()
    }
}

public final class NWParameters: @unchecked Sendable {
    public var includePeerToPeer = false
    public var requiredInterfaceType: NWInterface.InterfaceType = .other
    public var prohibitedInterfaceTypes: [NWInterface.InterfaceType]?
    public init() {}
    public convenience init(tls: NWProtocolTLS.Options?, tcp: NWProtocolTCP.Options = NWProtocolTCP.Options()) { self.init(); fakeTCP = tcp }
    public private(set) var fakeTCP: NWProtocolTCP.Options?
    public static var tcp: NWParameters { NWParameters() }
    public static var tls: NWParameters { NWParameters() }
}

public struct NWPath: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case satisfied, unsatisfied, requiresConnection }
    public enum UnsatisfiedReason: Sendable, Equatable { case notAvailable, cellularDenied, wifiDenied, localNetworkDenied, vpnInactive }
    public let status: Status
    public let unsatisfiedReason: UnsatisfiedReason
    public init(fakeStatus: Status, reason: UnsatisfiedReason = .notAvailable) { status = fakeStatus; unsatisfiedReason = reason }
}

public final class NWConnection: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case setup, waiting(NWError), preparing, ready, failed(NWError), cancelled
    }
    public final class ContentContext: @unchecked Sendable {
        public init() {}
        public static let defaultMessage = ContentContext()
        public static let finalMessage = ContentContext()
        public static let defaultStream = ContentContext()
    }
    public enum SendCompletion {
        @preconcurrency case contentProcessed(@Sendable (NWError?) -> Void)
        case idempotent
    }

    public private(set) var state: State = .setup
    @preconcurrency public var stateUpdateHandler: (@Sendable (State) -> Void)? {
        didSet { if let stateUpdateHandler { fakeLastHandler = stateUpdateHandler } }
    }
    public var currentPath: NWPath? { fakePath }
    public var viabilityUpdateHandler: (@Sendable (Bool) -> Void)?
    public var queue: DispatchQueue? { fakeQueue }

    public convenience init(host: NWEndpoint.Host, port: NWEndpoint.Port, using: NWParameters) {
        self.init(to: .hostPort(host: host, port: port), using: using)
    }
    public init(to endpoint: NWEndpoint, using: NWParameters) {
        self.endpoint = endpoint
        self.fakeParameters = using
        NWConnection.fakeAll.append(self)
        NWConnection.fakeOnCreate?(self)
    }
    public func start(queue: DispatchQueue) {
        fakeQueue = queue
        fakeStartCount += 1
        queue.async { [self] in
            guard state == .setup else { return }
            state = .preparing
            stateUpdateHandler?(.preparing)
            NWConnection.fakeOnAnyStart?(self)
        }
    }
    public func cancel() {
        fakeCancelCount += 1
        guard !fakeCancelDelivered else { return }
        fakeCancelDelivered = true
        guard let queue = fakeQueue else { state = .cancelled; return }
        queue.async { [self] in
            state = .cancelled
            stateUpdateHandler?(.cancelled)
            let waiting = pendingReceives
            pendingReceives = []
            for receive in waiting { receive(nil, nil, false, .posix(.ECANCELED)) }
        }
    }
    @preconcurrency public func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping @Sendable (Data?, ContentContext?, Bool, NWError?) -> Void) {
        pendingReceives.append(completion)
        fakeReceiveArmCount += 1
        pump()
    }
    public func send(content: Data?, contentContext: ContentContext = .defaultMessage, isComplete: Bool = true, completion: SendCompletion) {
        if let content { fakeSent.append(content) }
        guard case .contentProcessed(let block) = completion else { return }
        if fakeHoldSends {
            fakeHeldSendCompletions.append(block)
        } else {
            let error = fakeSendError
            (fakeQueue ?? .main).async { block(error) }
        }
    }

    // MARK: fake controls
    nonisolated(unsafe) public static var fakeAll: [NWConnection] = []
    nonisolated(unsafe) public static var fakeOnCreate: ((NWConnection) -> Void)?
    nonisolated(unsafe) public static var fakeOnAnyStart: ((NWConnection) -> Void)?
    public let endpoint: NWEndpoint
    public let fakeParameters: NWParameters
    public private(set) var fakeQueue: DispatchQueue?
    public var fakePath: NWPath?
    public var fakeSent: [Data] = []
    public var fakeSendError: NWError?
    public var fakeHoldSends = false
    public var fakeHeldSendCompletions: [@Sendable (NWError?) -> Void] = []
    public private(set) var fakeStartCount = 0
    public private(set) var fakeCancelCount = 0
    public private(set) var fakeReceiveArmCount = 0
    public private(set) var fakeLastHandler: (@Sendable (State) -> Void)?
    private var fakeCancelDelivered = false
    private var pendingReceives: [@Sendable (Data?, ContentContext?, Bool, NWError?) -> Void] = []
    private var inbox: [(Data?, Bool, NWError?)] = []

    public var fakeHost: String { if case .hostPort(let host, _) = endpoint { return host.debugDescription }; return "" }
    public var fakePendingReceives: Int { pendingReceives.count }

    /// A state change through whatever handler is installed when it is delivered.
    public func fakeSetState(_ next: State) {
        (fakeQueue ?? .main).async { [self] in
            state = next
            stateUpdateHandler?(next)
        }
    }
    /// A callback that was already in flight when the handler was cleared.
    public func fakeFireStaleHandler(_ next: State) {
        let handler = fakeLastHandler
        (fakeQueue ?? .main).async { handler?(next) }
    }
    /// Delivers to the armed receive, or waits for the next one.
    public func fakeDeliver(_ data: Data?, isComplete: Bool = false, error: NWError? = nil) {
        inbox.append((data, isComplete, error))
        pump()
    }
    public func fakeFinishHeldSends(error: NWError?) {
        let blocks = fakeHeldSendCompletions
        fakeHeldSendCompletions = []
        (fakeQueue ?? .main).async { for block in blocks { block(error) } }
    }
    private func pump() {
        while !pendingReceives.isEmpty, !inbox.isEmpty {
            let receive = pendingReceives.removeFirst()
            let (data, complete, error) = inbox.removeFirst()
            (fakeQueue ?? .main).async { receive(data, nil, complete, error) }
        }
    }
    public static func fakeResetAll() { fakeAll = []; fakeOnCreate = nil; fakeOnAnyStart = nil }
}

public final class NWBrowser: @unchecked Sendable {
    public enum Descriptor: Sendable, Hashable {
        case bonjour(type: String, domain: String?)
        case bonjourWithTXTRecord(type: String, domain: String?)
    }
    public enum State: Equatable, Sendable { case setup, ready, failed(NWError), cancelled, waiting(NWError) }
    public struct Result: Hashable, Sendable {
        public enum Change: Hashable, Sendable { case identical, added(Result), removed(Result), changed(old: Result, new: Result, flags: Int) }
        public let endpoint: NWEndpoint
        public let interfaces: [NWInterface]
        public init(fakeEndpoint: NWEndpoint) { endpoint = fakeEndpoint; interfaces = [] }
    }
    @preconcurrency public var stateUpdateHandler: (@Sendable (State) -> Void)?
    @preconcurrency public var browseResultsChangedHandler: (@Sendable (Set<Result>, Set<Result.Change>) -> Void)?
    public var browseResults: Set<Result> = []
    public init(for descriptor: Descriptor, using parameters: NWParameters) { NWBrowser.fakeAll.append(self) }
    public func start(queue: DispatchQueue) { fakeQueue = queue; fakeStarted = true }
    public func cancel() { fakeCancelled = true }
    nonisolated(unsafe) public static var fakeAll: [NWBrowser] = []
    public private(set) var fakeQueue: DispatchQueue?
    public private(set) var fakeStarted = false
    public private(set) var fakeCancelled = false
    public func fakeResults(_ names: [String]) {
        let results = Set(names.map { Result(fakeEndpoint: .service(name: $0, type: "_androidtvremote2._tcp", domain: "local.", interface: nil)) })
        browseResults = results
        (fakeQueue ?? .main).async { [self] in browseResultsChangedHandler?(results, []) }
    }
}

public final class NWPathMonitor: @unchecked Sendable {
    public init() { NWPathMonitor.fakeAll.append(self) }
    public init(requiredInterfaceType: NWInterface.InterfaceType) { NWPathMonitor.fakeAll.append(self) }
    public init(prohibitedInterfaceTypes: [NWInterface.InterfaceType]) { fakeProhibited = prohibitedInterfaceTypes; NWPathMonitor.fakeAll.append(self) }
    @preconcurrency public var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    public var currentPath: NWPath { NWPath(fakeStatus: .satisfied) }
    public func start(queue: DispatchQueue) { fakeQueue = queue }
    public func cancel() {}
    nonisolated(unsafe) public static var fakeAll: [NWPathMonitor] = []
    public private(set) var fakeQueue: DispatchQueue?
    public private(set) var fakeProhibited: [NWInterface.InterfaceType] = []
    public func fakeUpdate(_ path: NWPath) {
        (fakeQueue ?? .main).async { [self] in pathUpdateHandler?(path) }
    }
}
