import Foundation
import Network

// Runs against AndroidTVConnection in the phone binary and WatchTVConnection in the
// watch binary, through the `Conn` typealias each binary defines.

final class Rig {
    let conn = Conn()
    var lost: [ConnectionError] = []
    var changes = 0
    init() {
        conn.onSessionLost = { [weak self] error in self?.lost.append(error) }
        conn.onStateChange = { [weak self] in self?.changes += 1 }
    }
}

typealias ConnectOutcome = Result<Void, ConnectionError>

func startConnect(_ rig: Rig, _ tv: TVDevice) -> Task<ConnectOutcome, Never> {
    let c = rig.conn
    return Task { @MainActor in
        do {
            try await c.connect(to: tv)
            return .success(())
        } catch {
            return .failure(error as? ConnectionError ?? .unreachable("foreign error \(error)"))
        }
    }
}

/// The socket a connect just opened, past any counted before it.
func nextSocket(after count: Int) async -> NWConnection {
    await until { NWConnection.fakeAll.count > count }
    return NWConnection.fakeAll[count]
}

func handshake(_ socket: NWConnection) {
    socket.fakeSetState(.ready)
    socket.fakeDeliver(tvConfigure())
    socket.fakeDeliver(tvSetActive())
}

@discardableResult
func connectFully(_ rig: Rig, _ tv: TVDevice) async -> NWConnection {
    let count = NWConnection.fakeAll.count
    let task = startConnect(rig, tv)
    let socket = await nextSocket(after: count)
    handshake(socket)
    let outcome = await task.value
    if case .failure(let error) = outcome { check(false, "connect failed: \(error)") }
    return socket
}

func failure(_ outcome: ConnectOutcome) -> ConnectionError? {
    if case .failure(let error) = outcome { return error }
    return nil
}

let tvA = device("1")
let tvB = device("2")

func runConnectionTests() async {
    let label = String(describing: Conn.self)
    print("### connection tests against \(label)")

    await test("conn.handshake.setActive") {
        let rig = Rig()
        let start = Date()
        let socket = await connectFully(rig, tvA)
        check(Date().timeIntervalSince(start) < 1, "should not wait for the configure fallback")
        check(rig.conn.isConnected)
        check(rig.conn.connectedDeviceId == tvA.id)
        check(rig.conn.isSessionFresh)
        check(rig.lost.isEmpty)
        // min(615, 622) = 615. Bytes are the ones real TVs accept.
        check(socket.fakeSent == [RemoteProtocol.configureReply(features: 615), RemoteProtocol.setActiveReply(features: 615)], "handshake bytes changed: \(socket.fakeSent)")
        // Golden bytes worked out by hand from the proto, independent of the encoder.
        check(socket.fakeSent.first.map(hex) == "1E0A1C08E70412171801220131" + "2A0961747672656D6F7465" + "3205312E302E30", "configure reply: \(socket.fakeSent.first.map(hex) ?? "")")
        check(socket.fakeSent.last.map(hex) == "05120308E704", "set active reply: \(socket.fakeSent.last.map(hex) ?? "")")
    }

    await test("conn.handshake.configureOnly.2s") {
        let rig = Rig()
        let task = startConnect(rig, tvA)
        let socket = await nextSocket(after: 0)
        socket.fakeSetState(.ready)
        socket.fakeDeliver(tvConfigure())
        let start = Date()
        await settle()
        check(!rig.conn.isConnected, "must not be connected right after configure")
        let outcome = await task.value
        let elapsed = Date().timeIntervalSince(start)
        check(failure(outcome) == nil, "\(outcome)")
        check(rig.conn.isConnected)
        check(elapsed >= 1.9 && elapsed < 3, "took \(elapsed)")
    }

    await test("conn.handshake.nothing.8s") {
        let rig = Rig()
        let task = startConnect(rig, tvA)
        let socket = await nextSocket(after: 0)
        let start = Date()
        socket.fakeSetState(.ready)
        let outcome = await task.value
        let elapsed = Date().timeIntervalSince(start)
        check(failure(outcome) == .timeout, "\(outcome)")
        check(elapsed >= 7.5 && elapsed < 9, "took \(elapsed)")
        check(!rig.conn.isConnected)
        check(socket.fakeCancelCount >= 1, "socket must be closed")
        check(rig.lost.isEmpty, "a failed attempt is not a lost session")
    }

    await test("conn.open.timeout.10s") {
        let rig = Rig()
        let start = Date()
        let task = startConnect(rig, tvA)
        let socket = await nextSocket(after: 0)
        let outcome = await task.value
        let elapsed = Date().timeIntervalSince(start)
        check(failure(outcome) == .timeout, "\(outcome)")
        check(elapsed >= 9.5 && elapsed < 11, "took \(elapsed)")
        check(socket.fakeCancelCount >= 1)
    }

    await test("conn.noDoubleResume.failedThenCancelled") {
        let rig = Rig()
        let task = startConnect(rig, tvA)
        let socket = await nextSocket(after: 0)
        socket.fakeSetState(.failed(.tls(-9808)))
        socket.fakeSetState(.cancelled)
        socket.fakeFireStaleHandler(.cancelled)
        socket.fakeFireStaleHandler(.failed(.posix(.ECONNRESET)))
        let outcome = await task.value
        check(failure(outcome) == .certificateRejected, "\(outcome)")
        await settle()
        // Reported to crash in the old code when reconnecting after this.
        let second = await connectFully(rig, tvA)
        socket.fakeFireStaleHandler(.cancelled)
        await settle()
        check(rig.conn.isConnected)
        check(second !== socket)
        check(rig.lost.isEmpty)
    }

    await test("conn.noDoubleResume.readyThenFailed") {
        let rig = Rig()
        let task = startConnect(rig, tvA)
        let socket = await nextSocket(after: 0)
        socket.fakeSetState(.ready)
        socket.fakeSetState(.failed(.posix(.ECONNRESET)))
        socket.fakeSetState(.cancelled)
        let start = Date()
        let outcome = await task.value
        check(Date().timeIntervalSince(start) < 1, "should not wait for a timeout")
        if case .unreachable = failure(outcome) {} else { check(false, "\(outcome)") }
        check(rig.lost.isEmpty)
        check(!rig.conn.isConnected)
    }

    await test("conn.noDoubleResume.waitingThenCancelled") {
        let rig = Rig()
        let task = startConnect(rig, tvA)
        let socket = await nextSocket(after: 0)
        socket.fakeSetState(.waiting(.posix(.ENETDOWN)))
        socket.fakeSetState(.waiting(.posix(.ENETDOWN)))
        socket.fakeSetState(.cancelled)
        let start = Date()
        let outcome = await task.value
        check(Date().timeIntervalSince(start) < 1, "fail fast on .waiting (TN3135)")
        check(failure(outcome) == .noNetwork, "\(outcome)")
    }

    await test("conn.waiting.localNetworkDenied") {
        let rig = Rig()
        let task = startConnect(rig, tvA)
        let socket = await nextSocket(after: 0)
        socket.fakePath = NWPath(fakeStatus: .unsatisfied, reason: .localNetworkDenied)
        socket.fakeSetState(.waiting(.posix(.ECONNABORTED)))
        let outcome = await task.value
        check(failure(outcome) == .localNetworkDenied, "\(outcome)")
        check(failure(outcome)?.isTerminal == true)
    }

    await test("conn.eof.beforeHandshake") {
        let rig = Rig()
        let task = startConnect(rig, tvA)
        let socket = await nextSocket(after: 0)
        socket.fakeSetState(.ready)
        socket.fakeDeliver(nil, isComplete: true)
        let start = Date()
        let outcome = await task.value
        check(Date().timeIntervalSince(start) < 1)
        check(failure(outcome) == .closedBeforeHandshake, "\(outcome)")
        check(rig.lost.isEmpty)
    }

    await test("conn.remoteError.beforeHandshake") {
        let rig = Rig()
        let task = startConnect(rig, tvA)
        let socket = await nextSocket(after: 0)
        socket.fakeSetState(.ready)
        socket.fakeDeliver(tvError())
        let start = Date()
        let outcome = await task.value
        check(Date().timeIntervalSince(start) < 1)
        check(failure(outcome) == .closedBeforeHandshake, "\(outcome)")
    }

    await test("conn.eof.connected") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        socket.fakeDeliver(nil, isComplete: true)
        check(await until { !rig.conn.isConnected }, "EOF must clear isConnected")
        await settle()
        check(rig.lost == [.sessionLost], "lost: \(rig.lost)")
        check(socket.fakeCancelCount >= 1, "socket must be cancelled")
        check(!rig.conn.sendCommand(.ok), "send after EOF must report false")
        // Everything a dying socket does afterwards.
        socket.fakeFireStaleHandler(.cancelled)
        socket.fakeFireStaleHandler(.failed(.posix(.ECONNRESET)))
        socket.fakeDeliver(nil, isComplete: true)
        await settle()
        check(rig.lost.count == 1, "onSessionLost must fire once, got \(rig.lost)")
    }

    await test("conn.eof.withFinalData") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        socket.fakeDeliver(tvVolume(level: 7, max: 100), isComplete: true)
        check(await until { !rig.conn.isConnected })
        check(rig.conn.volumeLevel == 7, "last data before EOF should still be read")
        check(rig.lost.count == 1)
    }

    await test("conn.sessionLost.eachCause") {
        let causes: [(String, (NWConnection) -> Void, ConnectionError)] = [
            ("receive error", { $0.fakeDeliver(nil, error: .posix(.ECONNRESET)) }, .unreachable(NWError.posix(.ECONNRESET).localizedDescription)),
            ("state failed", { $0.fakeSetState(.failed(.posix(.ETIMEDOUT))) }, .timeout),
            ("state waiting", { $0.fakeSetState(.waiting(.posix(.ENETDOWN))) }, .noNetwork),
            ("state cancelled", { $0.fakeSetState(.cancelled) }, .sessionLost),
            ("tls failure", { $0.fakeSetState(.failed(.tls(-9808))) }, .certificateRejected),
        ]
        for (name, cause, expected) in causes {
            let rig = Rig()
            let socket = await connectFully(rig, tvA)
            cause(socket)
            check(await until { !rig.conn.isConnected }, "\(name) must clear isConnected")
            await settle()
            check(rig.lost == [expected], "\(name): \(rig.lost)")
        }
    }

    await test("conn.sessionLost.sendError") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        socket.fakeSendError = .posix(.EPIPE)
        check(rig.conn.sendCommand(.ok), "send is accepted, the failure comes later")
        check(await until { !rig.conn.isConnected }, "send error must clear isConnected")
        await settle()
        check(rig.lost.count == 1, "\(rig.lost)")
    }

    await test("conn.stale.oldSocketLeavesNewAlone") {
        let rig = Rig()
        let old = await connectFully(rig, tvA)
        old.fakeHoldSends = true
        check(rig.conn.sendCommand(.ok))

        let count = NWConnection.fakeAll.count
        let task = startConnect(rig, tvB)
        let new = await nextSocket(after: count)
        check(new !== old)
        check(old.fakeCancelCount >= 1, "old socket must be closed")

        // Late callbacks from the old socket, in every form.
        old.fakeFireStaleHandler(.cancelled)
        old.fakeFireStaleHandler(.failed(.posix(.ECONNRESET)))
        old.fakeDeliver(tvVolume(level: 99, max: 100))
        old.fakeFinishHeldSends(error: .posix(.EPIPE))
        await settle()
        check(rig.conn.connectedDeviceId == tvB.id)

        handshake(new)
        let outcome = await task.value
        check(failure(outcome) == nil, "\(outcome)")

        old.fakeFireStaleHandler(.cancelled)
        old.fakeDeliver(nil, isComplete: true)
        old.fakeFinishHeldSends(error: .posix(.EPIPE))
        await settle()
        check(rig.conn.isConnected, "stale callback killed the new session")
        check(rig.lost.isEmpty, "stale callback reported a loss: \(rig.lost)")
        check(rig.conn.volumeLevel == nil, "stale data leaked into the new session")
        check(new.fakePendingReceives == 1, "new socket must keep exactly one receive armed, has \(new.fakePendingReceives)")
        check(rig.conn.sendCommand(.home))
        check(new.fakeSent.last == RemoteProtocol.keyInject(keyCode: RemoteCommand.home.keyCode))
    }

    await test("conn.stale.queuedBeforeDisconnect") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        // Already on the queue when the user disconnects, in the same main queue turn.
        socket.fakeDeliver(tvVolume(level: 99, max: 100))
        socket.fakeDeliver(nil, isComplete: true)
        socket.fakeSetState(.failed(.posix(.ECONNRESET)))
        rig.conn.disconnect()
        await settle()
        check(rig.conn.volumeLevel == nil, "data queued before disconnect leaked: \(String(describing: rig.conn.volumeLevel))")
        check(rig.lost.isEmpty, "disconnect() then a queued EOF reported a loss: \(rig.lost)")
        check(!rig.conn.isConnected)
    }

    await test("conn.disconnect.duringOpen") {
        let rig = Rig()
        let task = startConnect(rig, tvA)
        let socket = await nextSocket(after: 0)
        let start = Date()
        rig.conn.disconnect()
        let outcome = await task.value
        check(Date().timeIntervalSince(start) < 0.3, "must resume promptly")
        check(failure(outcome) == .cancelled, "\(outcome)")
        check(socket.fakeCancelCount >= 1)
        check(rig.conn.connectedDeviceId == nil)
        check(rig.lost.isEmpty)
    }

    await test("conn.disconnect.duringHandshake") {
        let rig = Rig()
        let task = startConnect(rig, tvA)
        let socket = await nextSocket(after: 0)
        socket.fakeSetState(.ready)
        await settle()
        let start = Date()
        rig.conn.disconnect()
        let outcome = await task.value
        check(Date().timeIntervalSince(start) < 0.3, "must resume promptly")
        check(failure(outcome) == .cancelled, "\(outcome)")
        check(rig.lost.isEmpty)
        check(!rig.conn.isConnected)
    }

    await test("conn.disconnect.connected") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        socket.fakeDeliver(tvVolume(level: 5, max: 10))
        check(await until { rig.conn.volumeLevel == 5 })
        rig.conn.disconnect()
        await settle()
        check(!rig.conn.isConnected)
        check(rig.conn.volumeLevel == nil)
        check(rig.lost.isEmpty, "disconnect() must not report a lost session: \(rig.lost)")
    }

    await test("conn.concurrentConnect.secondWins") {
        let rig = Rig()
        let first = startConnect(rig, tvA)
        let socket1 = await nextSocket(after: 0)
        let second = startConnect(rig, tvB)
        let socket2 = await nextSocket(after: 1)
        check(failure(await first.value) == .cancelled)
        handshake(socket2)
        check(failure(await second.value) == nil)
        check(rig.conn.isConnected)
        check(rig.conn.connectedDeviceId == tvB.id)
        check(socket1.fakeCancelCount >= 1)
    }

    await test("conn.reuse.sameDevice") {
        let rig = Rig()
        await connectFully(rig, tvA)
        let count = NWConnection.fakeAll.count
        let outcome = await startConnect(rig, tvA).value
        check(failure(outcome) == nil)
        check(NWConnection.fakeAll.count == count, "must reuse the live session")
    }

    await test("conn.reconnect.differentDeviceClearsReadings") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        socket.fakeDeliver(tvVolume(level: 24, max: 100, muted: true))
        socket.fakeDeliver(tvApp(package: "com.netflix.ninja"))
        socket.fakeDeliver(tvPower(true))
        check(await until { rig.conn.isTVOn == true && rig.conn.volumeLevel == 24 && rig.conn.appPackage != "" })

        let count = NWConnection.fakeAll.count
        let task = startConnect(rig, tvB)
        let next = await nextSocket(after: count)
        check(rig.conn.volumeLevel == nil, "volume of the old TV")
        check(rig.conn.volumeMax == nil)
        check(rig.conn.volumeMuted == false)
        check(rig.conn.appPackage == "")
        check(rig.conn.appLabel == "")
        check(rig.conn.isTVOn == nil)
        handshake(next)
        _ = await task.value
        check(rig.conn.volumeLevel == nil)
    }

    await test("conn.reconnect.sameDeviceKeepsReadings") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        socket.fakeDeliver(tvVolume(level: 24, max: 100))
        socket.fakeDeliver(tvPower(true))
        check(await until { rig.conn.volumeLevel == 24 && rig.conn.isTVOn == true })
        socket.fakeDeliver(nil, isComplete: true)
        check(await until { !rig.conn.isConnected })
        check(rig.conn.volumeLevel == 24, "kept across a drop so the UI can dim it")
        await connectFully(rig, tvA)
        check(rig.conn.volumeLevel == 24)
        check(rig.conn.volumeMax == 100)
        check(rig.conn.isTVOn == nil, "power is unknown until the TV says again")
    }

    await test("conn.readings.decodeAndNotify") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        let baseline = rig.changes
        socket.fakeDeliver(tvVolume(level: 24, max: 100, muted: true))
        check(await until { rig.conn.volumeLevel == 24 })
        check(rig.conn.volumeMax == 100 && rig.conn.volumeMuted)
        // proto3: unmute and level 0 arrive as absent fields, and max stays known.
        socket.fakeDeliver(tvVolume(level: nil, max: nil))
        check(await until { rig.conn.volumeLevel == 0 })
        check(rig.conn.volumeMuted == false, "stuck muted")
        check(rig.conn.volumeMax == 100, "max lost")
        socket.fakeDeliver(tvPower(false))
        check(await until { rig.conn.isTVOn == false })
        socket.fakeDeliver(tvPower(true))
        check(await until { rig.conn.isTVOn == true })
        socket.fakeDeliver(tvApp(label: "Netflix", package: "com.netflix.ninja"))
        check(await until { rig.conn.appLabel == "Netflix" })
        check(rig.conn.appPackage == "com.netflix.ninja")
        check(rig.changes >= baseline + 5, "onStateChange count \(rig.changes - baseline)")
    }

    await test("conn.framing.splitAcrossReceives") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        var big = ProtobufEncoder()
        big.addString(field: 12, value: String(repeating: "a", count: 300))
        var ime = ProtobufEncoder()
        ime.addMessage(field: 1, encoder: big)
        var message = ProtobufEncoder()
        message.addMessage(field: 20, encoder: ime)
        let frame = MessageFraming.frame(message.encoded)
        // The first split lands inside the two-byte length varint.
        socket.fakeDeliver(frame.prefix(1))
        socket.fakeDeliver(frame.dropFirst().prefix(1))
        socket.fakeDeliver(frame.dropFirst(2).prefix(100))
        socket.fakeDeliver(frame.dropFirst(102))
        check(await until { rig.conn.appPackage.count == 300 }, "split frame lost")
        // Two frames in one read.
        socket.fakeDeliver(tvPing(1) + tvPing(2))
        check(await until { socket.fakeSent.suffix(2) == [RemoteProtocol.pingResponse(value: 1), RemoteProtocol.pingResponse(value: 2)] })
    }

    await test("conn.framing.garbageDoesNotTrap") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        socket.fakeDeliver(Data(repeating: 0xFF, count: 11))
        socket.fakeDeliver(Data([0x05, 0x0A, 0xFF, 0xFF, 0xFF, 0xFF]))
        await settle()
        // Whether the session survives garbage is unspecified. It must just not crash.
        check(true)
    }

    await test("conn.framing.corruptEndsSession") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        let sentBefore = socket.fakeSent.count
        socket.fakeDeliver(ProtobufEncoder.varint(1 << 40))
        check(await until { !rig.conn.isConnected }, "an implausible length must end the session")
        await settle()
        check(rig.lost == [.sessionLost], "\(rig.lost)")
        check(socket.fakeCancelCount >= 1)
        check(socket.fakeSent.count == sentBefore, "no bytes on a corrupt stream")
    }

    await test("conn.framing.corruptDuringHandshake") {
        let rig = Rig()
        let task = startConnect(rig, tvA)
        let socket = await nextSocket(after: 0)
        socket.fakeSetState(.ready)
        socket.fakeDeliver(Data(repeating: 0xFF, count: 11))
        let start = Date()
        let outcome = await task.value
        check(Date().timeIntervalSince(start) < 1, "should not wait for the handshake deadline")
        check(failure(outcome) == .sessionLost, "\(outcome)")
        check(rig.lost.isEmpty)
    }

    await test("conn.remoteError.afterHandshake") {
        let rig = Rig()
        var errors = 0
        rig.conn.onRemoteError = { errors += 1 }
        let socket = await connectFully(rig, tvA)
        let sentBefore = socket.fakeSent.count
        socket.fakeDeliver(tvError())
        check(await until { errors == 1 }, "\(errors)")
        await settle()
        check(rig.conn.isConnected, "the session stays up")
        check(rig.lost.isEmpty)
        check(socket.fakeSent.count == sentBefore, "no reply to remote_error")
    }

    await test("conn.tcpOptions") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        let tcp = socket.fakeParameters.fakeTCP
        check(tcp?.noDelay == true)
        check(tcp?.enableKeepalive == true)
        check((tcp?.connectionDropTime ?? 0) > 0, "unacked sends must be able to fail the socket")
    }

    await test("conn.watchdog.pressesOnlyHideSilenceForSoLong") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        let start = Date()
        let presser = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                _ = rig.conn.sendCommand(.right)
            }
        }
        await sleepMs(25_000)
        check(rig.conn.isConnected, "sends must count: the TV only pings when no command is sent")
        check(rig.conn.isSessionFresh)
        check(await until(45) { !rig.conn.isConnected }, "a TV that never answers must not stay connected forever")
        let elapsed = Date().timeIntervalSince(start)
        presser.cancel()
        check(elapsed >= 59 && elapsed < 66, "fired after \(elapsed)")
        check(rig.lost == [.sessionLost], "\(rig.lost)")
        check(socket.fakeCancelCount >= 1)
    }

    await test("conn.ping.replyEchoesValue") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        socket.fakeDeliver(tvPing(42))
        check(await until { socket.fakeSent.last == RemoteProtocol.pingResponse(value: 42) })
    }

    await test("conn.sendCommand") {
        let rig = Rig()
        check(!rig.conn.sendCommand(.ok), "no session yet")
        let socket = await connectFully(rig, tvA)
        check(rig.conn.sendCommand(.volumeUp))
        check(socket.fakeSent.last == RemoteProtocol.keyInject(keyCode: 24))
        check(rig.conn.sendCommand(.playPause, direction: .startLong))
        check(socket.fakeSent.last == RemoteProtocol.keyInject(keyCode: 85, direction: .startLong))
    }

    await test("conn.noIdentity") {
        fakeSetIdentityAvailable(false)
        defer { fakeSetIdentityAvailable(true) }
        let rig = Rig()
        let outcome = await startConnect(rig, tvA).value
        check(failure(outcome) == .noIdentity, "\(outcome)")
        check(NWConnection.fakeAll.isEmpty, "no socket without an identity")
    }

    await test("conn.watchdog.silenceAndPings") {
        let silent = Rig()
        let chatty = Rig()
        await connectFully(silent, tvA)
        let chattySocket = await connectFully(chatty, tvB)
        let start = Date()

        // A TV that pings every 5s must stay up well past the timeout.
        let pinger = Task { @MainActor in
            var n: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                n += 1
                chattySocket.fakeDeliver(tvPing(n))
            }
        }
        await sleepMs(12_000)
        check(silent.conn.isConnected, "fired too early")
        check(silent.conn.isSessionFresh)
        check(await until(10) { !silent.conn.isConnected }, "watchdog never fired")
        let elapsed = Date().timeIntervalSince(start)
        check(elapsed >= 15.5 && elapsed < 21, "fired after \(elapsed)")
        check(silent.lost == [.sessionLost], "\(silent.lost)")
        check(!silent.conn.isSessionFresh)
        check(chatty.conn.isConnected, "pings must keep the session alive")
        check(chatty.lost.isEmpty)
        check(chatty.conn.isSessionFresh)
        pinger.cancel()
    }
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined()
}
