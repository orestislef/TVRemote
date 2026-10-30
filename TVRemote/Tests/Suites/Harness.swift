import Foundation
import Network

// Hand-rolled test runner. Real time, real main queue, real Swift concurrency.
var testsPassed = 0
var testsFailed = 0
var checksPassed = 0
var checksFailed = 0
var currentFailed = false
var failureLines: [String] = []
var currentName = ""
let filters = Array(CommandLine.arguments.dropFirst())

func check(_ condition: Bool, _ message: String = "", line: Int = #line) {
    if condition {
        checksPassed += 1
    } else {
        checksFailed += 1
        currentFailed = true
        let text = "FAIL [\(currentName)] line \(line): \(message)"
        failureLines.append(text)
        print("  " + text)
    }
}

func test(_ name: String, _ body: () async throws -> Void) async {
    if !filters.isEmpty, !filters.contains(where: { name.hasPrefix($0) }) { return }
    currentName = name
    currentFailed = false
    print("RUN  \(name)")
    fflush(stdout)
    let start = Date()
    NWConnection.fakeResetAll()
    do {
        try await body()
    } catch {
        check(false, "threw \(error)")
    }
    let elapsed = String(format: "%.2fs", Date().timeIntervalSince(start))
    if currentFailed { testsFailed += 1 } else { testsPassed += 1 }
    print("\(currentFailed ? "FAIL" : "PASS") \(name) (\(elapsed))")
    fflush(stdout)
}

func finish() -> Never {
    print("\n=== tests: \(testsPassed) passed, \(testsFailed) failed. checks: \(checksPassed) passed, \(checksFailed) failed")
    for line in failureLines { print(line) }
    fflush(stdout)
    exit(testsFailed == 0 ? 0 : 1)
}

func sleepMs(_ ms: Int) async {
    try? await Task.sleep(for: .milliseconds(ms))
}

/// Lets queued main-queue work and main actor tasks run.
func settle() async {
    await sleepMs(30)
}

@discardableResult
func until(_ timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        await sleepMs(5)
    }
    return condition()
}

// MARK: - TV side frames

func tvFrame(_ field: Int, _ build: (inout ProtobufEncoder) -> Void) -> Data {
    var body = ProtobufEncoder()
    build(&body)
    var message = ProtobufEncoder()
    message.addMessage(field: field, encoder: body)
    return MessageFraming.frame(message.encoded)
}
let tvFeatures: UInt64 = 622
func tvConfigure() -> Data { tvFrame(1) { $0.addVarint(field: 1, value: tvFeatures) } }
func tvSetActive() -> Data { tvFrame(2) { $0.addVarint(field: 1, value: tvFeatures) } }
func tvError() -> Data { tvFrame(3) { $0.addVarint(field: 1, value: 1) } }
func tvPing(_ value: UInt64) -> Data { tvFrame(8) { $0.addVarint(field: 1, value: value) } }
func tvPower(_ on: Bool) -> Data { tvFrame(40) { if on { $0.addVarint(field: 1, value: 1) } } }
func tvVolume(level: UInt64?, max: UInt64?, muted: Bool = false) -> Data {
    tvFrame(50) {
        if let max { $0.addVarint(field: 6, value: max) }
        if let level { $0.addVarint(field: 7, value: level) }
        if muted { $0.addVarint(field: 8, value: 1) }
    }
}
func tvApp(label: String = "", package: String) -> Data {
    var app = ProtobufEncoder()
    if !label.isEmpty { app.addString(field: 10, value: label) }
    app.addString(field: 12, value: package)
    var ime = ProtobufEncoder()
    ime.addMessage(field: 1, encoder: app)
    var message = ProtobufEncoder()
    message.addMessage(field: 20, encoder: ime)
    return MessageFraming.frame(message.encoded)
}

// MARK: - Scripted TV

enum TVBehavior {
    case online
    case refused
    case tlsReject
    case eofAfterReady
    case silent
    case networkDown
}
var defaultBehavior: TVBehavior = .online
var behaviorByHost: [String: TVBehavior] = [:]

func apply(_ behavior: TVBehavior, to socket: NWConnection) {
    switch behavior {
    case .online:
        socket.fakeSetState(.ready)
        socket.fakeDeliver(tvConfigure())
        socket.fakeDeliver(tvSetActive())
    case .refused:
        socket.fakeSetState(.failed(.posix(.ECONNREFUSED)))
    case .tlsReject:
        socket.fakeSetState(.failed(.tls(-9808)))
    case .eofAfterReady:
        socket.fakeSetState(.ready)
        socket.fakeDeliver(nil, isComplete: true)
    case .silent:
        break
    case .networkDown:
        socket.fakeSetState(.waiting(.posix(.ENETDOWN)))
    }
}

func installScriptedTV(_ behavior: TVBehavior = .online) {
    defaultBehavior = behavior
    behaviorByHost = [:]
    NWConnection.fakeOnAnyStart = { socket in
        apply(behaviorByHost[socket.fakeHost] ?? defaultBehavior, to: socket)
    }
}

func sockets(to host: String) -> [NWConnection] {
    NWConnection.fakeAll.filter { $0.fakeHost == host }
}

func device(_ id: String, name: String? = nil, host: String? = nil) -> TVDevice {
    TVDevice(id: id, name: name ?? "TV-\(id)", host: host ?? "10.0.0.\(id)", port: 6466, isPaired: true)
}
