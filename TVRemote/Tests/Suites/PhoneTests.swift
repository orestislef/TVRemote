import Foundation
import Network
import UIKit
import WatchConnectivity

func makeManager(_ devices: [TVDevice], foreground: Bool = true) -> TVManager {
    UserDefaults.standard.removeObject(forKey: "paired_tv_devices")
    UserDefaults.standard.removeObject(forKey: "last_connected_device_id")
    WCSession.default.fakeReset()
    let manager = TVManager()
    PhoneSessionManager.shared.tvManager = manager
    if foreground { manager.appDidBecomeActive() }
    manager.pairedDevices = devices
    return manager
}

func path(_ up: Bool) -> NWPath {
    NWPath(fakeStatus: up ? .satisfied : .unsatisfied)
}

final class ReplyBox {
    var replies: [[String: Any]] = []
    var first: [String: Any]? { replies.first }
    var status: String? { first?["status"] as? String }
    var failure: String? { first?["failure"] as? String }
    var state: TVStatus? { (first?["state"] as? [String: Any]).flatMap { TVStatus(wire: $0) } }
}

/// A message from the Watch. The reply is checked to arrive, and only once.
func ask(_ message: [String: Any], timeout: Double = 5, line: Int = #line) async -> ReplyBox {
    let box = ReplyBox()
    WCSession.default.fakeIncoming(message) { reply in box.replies.append(reply) }
    let replied = await until(timeout) { !box.replies.isEmpty }
    check(replied, "no reply to \(message) within \(timeout)s", line: line)
    await settle()
    check(box.replies.count <= 1, "replied \(box.replies.count) times to \(message)", line: line)
    return box
}

func runManagerTests() async {
    print("### TVManager tests")

    await test("mgr.connect.happyPath") {
        installScriptedTV(.online)
        let m = makeManager([tvA, tvB])
        var fired = 0
        m.onStatusChange = { fired += 1 }
        check(m.phase == .idle)
        m.connect(to: tvB)
        check(m.phase == .connecting, "\(m.phase)")
        check(m.activeDevice?.id == tvB.id)
        check(m.phase(for: tvA) == .idle)
        check(m.phase(for: tvB) == .connecting)
        check(await until { m.phase == .connected(.direct) }, "\(m.phase)")
        check(fired >= 2, "onStatusChange fired \(fired)")
        let s = m.status
        check(s.phase == .connected(.direct))
        check(s.deviceId == tvB.id)
        check(m.sendCommand(.ok))
        check(sockets(to: tvB.host).last?.fakeSent.last == RemoteProtocol.keyInject(keyCode: 23))
        check(UserDefaults.standard.string(forKey: "last_connected_device_id") == tvB.id)
        m.disconnect()
    }

    await test("mgr.dedupe.sameDevice") {
        installScriptedTV(.silent)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        m.connect(to: tvA)
        await settle()
        m.connect(to: tvA)
        await settle()
        check(NWConnection.fakeAll.count == 1, "opened \(NWConnection.fakeAll.count) sockets")
        let waiter = Task { @MainActor in try await m.connectAndWait(to: tvA) }
        await settle()
        check(NWConnection.fakeAll.count == 1, "connectAndWait opened another socket")
        handshake(NWConnection.fakeAll[0])
        do {
            try await waiter.value
        } catch {
            check(false, "waiter threw \(error)")
        }
        check(m.phase == .connected(.direct))
        m.connect(to: tvA)
        await settle()
        check(NWConnection.fakeAll.count == 1, "a live session must be reused")
        m.disconnect()
    }

    await test("mgr.differentDevice.cancelsAttempt") {
        installScriptedTV(.silent)
        let m = makeManager([tvA, tvB])
        m.connect(to: tvA)
        await settle()
        let waiterA = Task { @MainActor () -> Bool in
            do { try await m.connectAndWait(to: tvA); return true } catch { return false }
        }
        await settle()
        behaviorByHost[tvB.host] = .online
        m.connect(to: tvB)
        check(m.activeDevice?.id == tvB.id)
        check(await until { m.phase == .connected(.direct) }, "\(m.phase)")
        check(m.activeDevice?.id == tvB.id)
        check(await waiterA.value == false, "the replaced attempt must not report success")
        check(sockets(to: tvA.host).first?.fakeCancelCount ?? 0 >= 1)
        await settle()
        check(m.phase == .connected(.direct), "late cancel moved phase to \(m.phase)")
        check(m.sendCommand(.ok))
        check(sockets(to: tvB.host).last?.fakeSent.last == RemoteProtocol.keyInject(keyCode: 23))
        m.disconnect()
    }

    await test("mgr.differentDevice.sameTurn") {
        installScriptedTV(.online)
        let m = makeManager([tvA, tvB])
        m.connect(to: tvA)
        m.connect(to: tvB)
        check(await until { m.phase == .connected(.direct) })
        check(m.activeDevice?.id == tvB.id)
        check(m.remoteConnection.connectedDeviceId == tvB.id, "session belongs to \(m.remoteConnection.connectedDeviceId ?? "nil")")
        check(sockets(to: tvA.host).isEmpty, "a replaced attempt must not open a socket to the other TV, opened \(sockets(to: tvA.host).count)")
        m.disconnect()
    }

    await test("mgr.differentDevice.clearsReadings") {
        installScriptedTV(.online)
        let m = makeManager([tvA, tvB])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        let socket = NWConnection.fakeAll[0]
        socket.fakeDeliver(tvVolume(level: 24, max: 100, muted: true))
        socket.fakeDeliver(tvApp(label: "Netflix", package: "com.netflix.ninja"))
        socket.fakeDeliver(tvPower(true))
        check(await until { m.status.volumeLevel == 24 && m.status.appLabel == "Netflix" && m.status.isOn == true })

        behaviorByHost[tvB.host] = .silent
        m.connect(to: tvB)
        // Same turn: this is what the first frame and the first tvState show.
        let s = m.status
        check(s.deviceId == tvB.id)
        check(s.volumeLevel == nil, "B shows A's volume \(String(describing: s.volumeLevel))")
        check(s.volumeMax == nil, "B shows A's max")
        check(s.isMuted == false, "B shows A's mute")
        check(s.appLabel == "", "B shows A's app")
        check(s.isOn == nil, "B shows A's power")
        await settle()
        check(m.status.volumeLevel == nil)
        m.disconnect()
    }

    await test("mgr.connectAndWait.failure") {
        installScriptedTV(.tlsReject)
        let m = makeManager([tvA])
        do {
            try await m.connectAndWait(to: tvA)
            check(false, "should throw")
        } catch {
            check(error as? ConnectionError == .certificateRejected, "\(error)")
        }
        check(m.phase == .failed(.needsPairing), "\(m.phase)")
        check(m.activeDevice?.id == tvA.id, "failed keeps the device so Retry knows it")
        check(sockets(to: tvA.host).count == 1, "terminal errors don't retry, got \(sockets(to: tvA.host).count)")
    }

    await test("mgr.retry.backoffStopsAtBudget") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        let first = NWConnection.fakeAll[0]
        defaultBehavior = .refused
        let start = Date()
        first.fakeDeliver(nil, isComplete: true)
        check(await until { m.phase == .reconnecting }, "\(m.phase)")
        // 1+2+4+8+8 = 23s, plus one 5s rediscovery probe.
        check(await until(40) { m.phase.failure != nil }, "never gave up, \(m.phase)")
        let elapsed = Date().timeIntervalSince(start)
        check(m.phase == .failed(.tvUnreachable), "\(m.phase)")
        check(NWConnection.fakeAll.count == 1 + 5, "expected 5 retries, got \(NWConnection.fakeAll.count - 1)")
        check(elapsed >= 22 && elapsed < 32, "took \(elapsed)")
        let count = NWConnection.fakeAll.count
        await sleepMs(3000)
        check(NWConnection.fakeAll.count == count, "kept retrying after the budget")

        // Retry resets the budget and goes right away.
        defaultBehavior = .online
        m.retry()
        check(await until(2) { m.phase == .connected(.direct) }, "retry should connect at once, \(m.phase)")
        m.disconnect()
    }

    await test("mgr.retry.recoversDuringBackoff") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        let first = NWConnection.fakeAll[0]
        first.fakeDeliver(nil, isComplete: true)
        check(await until { m.phase == .reconnecting })
        check(await until(3) { m.phase == .connected(.direct) }, "\(m.phase)")
        check(m.sendCommand(.ok))
        m.disconnect()
    }

    await test("mgr.retry.closedBeforeHandshakeIsConfirmed") {
        installScriptedTV(.eofAfterReady)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until(2) { m.phase == .reconnecting }, "should retry before blaming pairing, \(m.phase)")
        check(await until(30) { m.phase.failure != nil }, "\(m.phase)")
        check(m.phase == .failed(.needsPairing), "\(m.phase)")
        check(NWConnection.fakeAll.count == 6, "got \(NWConnection.fakeAll.count) attempts")
    }

    await test("mgr.disconnect.stopsEverything") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        defaultBehavior = .refused
        NWConnection.fakeAll[0].fakeDeliver(nil, isComplete: true)
        check(await until { m.phase == .reconnecting })
        m.disconnect()
        check(m.phase == .idle)
        check(m.activeDevice == nil)
        let count = NWConnection.fakeAll.count
        await sleepMs(2500)
        check(NWConnection.fakeAll.count == count, "retried after disconnect")
        check(m.phase == .idle, "\(m.phase)")
        m.appDidEnterBackground()
        m.appDidBecomeActive()
        await settle()
        check(NWConnection.fakeAll.count == count, "foregrounding must respect the disconnect")
        check(m.phase == .idle)
        check(!m.sendCommand(.ok))
    }

    await test("mgr.disconnect.afterSocketReadyNoGhost") {
        installScriptedTV(.silent)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        await settle()
        let socket = NWConnection.fakeAll[0]
        socket.fakeSetState(.ready)
        socket.fakeDeliver(tvConfigure())
        await settle()
        m.disconnect()
        socket.fakeDeliver(tvSetActive())
        await sleepMs(2500)
        check(m.phase == .idle, "\(m.phase)")
        check(m.activeDevice == nil)
        check(!m.remoteConnection.isConnected)
    }

    await test("mgr.remove.duringConnect") {
        installScriptedTV(.silent)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        await settle()
        m.removePairedDevice(tvA)
        check(m.phase == .idle)
        check(m.activeDevice == nil)
        check(m.pairedDevices.isEmpty)
        handshake(NWConnection.fakeAll[0])
        await settle()
        check(m.phase == .idle, "\(m.phase)")
        check(!m.remoteConnection.isConnected, "ghost session to a removed TV")
    }

    await test("mgr.background.lostSessionGoesIdle") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        WCSession.default.fakeSetReachable(true, notify: false)
        m.appDidEnterBackground()
        check(m.phase == .connected(.direct), "watch reachable: keep the session in background")
        NWConnection.fakeAll[0].fakeDeliver(nil, isComplete: true)
        check(await until { m.phase == .idle }, "\(m.phase)")
        let count = NWConnection.fakeAll.count
        await sleepMs(1500)
        check(NWConnection.fakeAll.count == count, "no retries from the background")
        m.appDidBecomeActive()
        check(await until { m.phase == .connected(.direct) }, "foregrounding reconnects, \(m.phase)")
        m.disconnect()
    }

    await test("mgr.background.noWatchClosesSession") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        m.appDidEnterBackground()
        check(m.phase == .idle, "\(m.phase)")
        check(!m.remoteConnection.isConnected)
        m.appDidBecomeActive()
        check(await until { m.phase == .connected(.direct) }, "resumes last device, \(m.phase)")
        m.disconnect()
    }

    await test("mgr.foreground.staleSocketIsReplaced") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        WCSession.default.fakeSetReachable(true, notify: false)
        m.appDidEnterBackground()
        await sleepMs(16_500)
        // The watchdog closes it while running, which is what a suspension prevents, so
        // this only covers the path where it already went idle or a fresh socket follows.
        m.appDidBecomeActive()
        check(await until { m.phase == .connected(.direct) }, "\(m.phase)")
        check(m.remoteConnection.isSessionFresh)
        check(NWConnection.fakeAll.count == 2, "got \(NWConnection.fakeAll.count) sockets")
        m.disconnect()
    }

    await test("mgr.network.downAndBack") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        let monitor = NWPathMonitor.fakeAll.last!
        check(monitor.fakeProhibited == [.cellular], "cellular must not count")
        defaultBehavior = .networkDown
        NWConnection.fakeAll[0].fakeDeliver(nil, isComplete: true)
        check(await until { m.phase == .reconnecting })
        monitor.fakeUpdate(path(false))
        check(await until { m.phase == .failed(.noWiFi) }, "\(m.phase)")
        let count = NWConnection.fakeAll.count
        await sleepMs(1500)
        check(NWConnection.fakeAll.count == count, "still retrying without a network")
        defaultBehavior = .online
        monitor.fakeUpdate(path(true))
        check(await until(2) { m.phase == .connected(.direct) }, "network back should retry, \(m.phase)")
        m.disconnect()
    }

    await test("mgr.network.downAtConnect") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        NWPathMonitor.fakeAll.last!.fakeUpdate(path(false))
        await settle()
        m.connect(to: tvA)
        check(await until(1) { m.phase == .failed(.noWiFi) }, "\(m.phase)")
        check(NWConnection.fakeAll.isEmpty, "no socket without a network")
    }

    await test("mgr.ipChange.rediscovers") {
        installScriptedTV(.silent)
        var moved = tvA
        moved.host = "10.0.0.99"
        behaviorByHost[tvA.host] = .refused
        behaviorByHost[moved.host] = .online
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { sockets(to: tvA.host).count == 1 })
        await sleepMs(300)
        check(m.phase == .connecting, "\(m.phase)")
        m.discovery.onDeviceResolved?(TVDevice(id: "10.0.0.99:6466", name: tvA.name, host: "10.0.0.99", port: 6466, isPaired: false))
        check(await until(2) { m.phase == .connected(.direct) }, "should reconnect at the new address, \(m.phase)")
        check(m.pairedDevices[0].host == "10.0.0.99")
        check(m.pairedDevices[0].id == tvA.id, "id stays stable")
        check(m.activeDevice?.host == "10.0.0.99")
        m.disconnect()
    }

    await test("mgr.status.afterFailedKeepsDevice") {
        installScriptedTV(.networkDown)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until(40) { m.phase.failure != nil }, "\(m.phase)")
        check(m.phase == .failed(.noWiFi), "\(m.phase)")
        check(m.status.deviceId == tvA.id)
    }
}

func runRelayTests() async {
    print("### PhoneSessionManager relay tests")

    await test("relay.everyPathReplies") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        let devices = await ask(["action": "getDevices"])
        check((devices.first?["devices"] as? [[String: Any]])?.count == 1)
        let state = await ask(["action": "getState"])
        check(state.state?.phase == .idle, "\(String(describing: state.first))")
        let noAction = await ask(["hello": 1])
        check(noAction.status == "error" && noAction.failure != nil, "\(String(describing: noAction.first))")
        let unknown = await ask(["action": "wat"])
        check(unknown.status == "error" && unknown.failure != nil)
        let badCommand = await ask(["action": "command", "command": "nope"])
        check(badCommand.status == "error" && badCommand.failure != nil)
        let badDevice = await ask(["action": "connect", "deviceId": "nope"])
        check(badDevice.status == "error" && badDevice.failure == ConnectionFailure.needsPairing.rawValue)
        check(badDevice.first?["message"] is String)
        let noDevice = await ask(["action": "connect"])
        check(noDevice.status == "error")
        let badCommandDevice = await ask(["action": "command", "command": "ok", "deviceId": "nope"])
        check(badCommandDevice.status == "error" && badCommandDevice.failure == ConnectionFailure.needsPairing.rawValue)
        let disconnect = await ask(["action": "disconnect"])
        check(disconnect.status == "disconnected")
        m.disconnect()
    }

    await test("relay.noManagerStillReplies") {
        _ = makeManager([])
        PhoneSessionManager.shared.tvManager = nil
        let reply = await ask(["action": "getDevices"])
        check(reply.status == "error", "\(String(describing: reply.first))")
    }

    await test("relay.noReplyVariantIsHandled") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        m.appDidEnterBackground()
        await settle()
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        // Sent with no reply handler: must still act.
        WCSession.default.fakeIncoming(["action": "disconnect"], reply: nil)
        check(await until { m.phase == .idle }, "background phone should drop on disconnect, \(m.phase)")
    }

    await test("relay.connect.replyShapes") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        let ok = await ask(["action": "connect", "deviceId": tvA.id])
        check(ok.status == "connected", "\(String(describing: ok.first))")
        check(ok.state?.phase == .connected(.viaPhone), "wire state \(String(describing: ok.state))")
        check(ok.state?.deviceId == tvA.id)
        m.disconnect()

        installScriptedTV(.tlsReject)
        let bad = await ask(["action": "connect", "deviceId": tvA.id])
        check(bad.status == "error")
        check(bad.failure == ConnectionFailure.needsPairing.rawValue, "\(String(describing: bad.first))")
        check(bad.first?["message"] is String)
        check(bad.first?["state"] == nil)
    }

    await test("relay.connect.answersWithinWait") {
        installScriptedTV(.silent)
        let m = makeManager([tvA])
        // Foreground, so retries run long past what the Watch waits for.
        let start = Date()
        let reply = await ask(["action": "connect", "deviceId": tvA.id], timeout: 25)
        let elapsed = Date().timeIntervalSince(start)
        check(reply.status == "error", "\(String(describing: reply.first))")
        check(elapsed < 22, "took \(elapsed)")
        m.disconnect()
    }

    await test("relay.disconnect.foregroundKeepsSession") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        let reply = await ask(["action": "disconnect"])
        check(reply.status == "disconnected")
        check(m.phase == .connected(.direct), "foreground phone must stay connected, \(m.phase)")
        m.disconnect()
    }

    await test("relay.command.connectedAndBytes") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        let reply = await ask(["action": "command", "command": "volumeUp", "deviceId": tvA.id])
        check(reply.status == "ok", "\(String(describing: reply.first))")
        check(reply.state?.phase == .connected(.viaPhone))
        check(NWConnection.fakeAll[0].fakeSent.last == RemoteProtocol.keyInject(keyCode: 24))
        m.disconnect()
    }

    await test("relay.command.reconnectsFirst") {
        installScriptedTV(.online)
        let m = makeManager([tvA, tvB], foreground: false)
        check(m.phase == .idle)
        let reply = await ask(["action": "command", "command": "ok", "deviceId": tvB.id])
        check(reply.status == "ok", "\(String(describing: reply.first))")
        check(m.activeDevice?.id == tvB.id)
        check(sockets(to: tvB.host).first?.fakeSent.last == RemoteProtocol.keyInject(keyCode: 23), "key must land on the socket it reconnected")
        m.disconnect()
    }

    await test("relay.command.lastDeviceWithoutId") {
        installScriptedTV(.online)
        let m = makeManager([tvA], foreground: false)
        let reply = await ask(["action": "command", "command": "home"])
        check(reply.status == "ok", "\(String(describing: reply.first))")
        check(m.activeDevice?.id == tvA.id)
        m.disconnect()
    }

    await test("relay.command.failureIsReported") {
        installScriptedTV(.tlsReject)
        let m = makeManager([tvA], foreground: false)
        let reply = await ask(["action": "command", "command": "ok", "deviceId": tvA.id])
        check(reply.status == "error", "\(String(describing: reply.first))")
        check(reply.failure == ConnectionFailure.needsPairing.rawValue)
        m.disconnect()
    }

    await test("relay.command.burstKeepsOrder") {
        installScriptedTV(.silent)
        let m = makeManager([tvA], foreground: false)
        let names = ["up", "down", "left", "right", "ok"]
        let boxes = names.map { _ in ReplyBox() }
        for (name, box) in zip(names, boxes) {
            WCSession.default.fakeIncoming(["action": "command", "command": name, "deviceId": tvA.id]) { reply in box.replies.append(reply) }
            await sleepMs(5)
        }
        await settle()
        check(NWConnection.fakeAll.count == 1, "a burst must share one connection, \(NWConnection.fakeAll.count)")
        let socket = NWConnection.fakeAll[0]
        handshake(socket)
        check(await until { boxes.allSatisfy { !$0.replies.isEmpty } }, "not all replied")
        let keys = [RemoteCommand.up, .down, .left, .right, .ok].map { RemoteProtocol.keyInject(keyCode: $0.keyCode) }
        check(Array(socket.fakeSent.suffix(5)) == keys, "order lost")
        check(boxes.allSatisfy { $0.status == "ok" })
        m.disconnect()
    }

    await test("relay.command.burstSharesFailure") {
        installScriptedTV(.tlsReject)
        let m = makeManager([tvA], foreground: false)
        let boxes = (0..<4).map { _ in ReplyBox() }
        for box in boxes {
            WCSession.default.fakeIncoming(["action": "command", "command": "ok", "deviceId": tvA.id]) { reply in box.replies.append(reply) }
        }
        check(await until { boxes.allSatisfy { !$0.replies.isEmpty } }, "not all replied")
        check(boxes.allSatisfy { $0.status == "error" })
        check(NWConnection.fakeAll.count == 1, "a burst must fail together, \(NWConnection.fakeAll.count) sockets")
        m.disconnect()
    }

    await test("relay.tvState.coalesced") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        WCSession.default.fakeSetReachable(true, notify: false)
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        await sleepMs(250)
        let socket = NWConnection.fakeAll[0]
        let before = WCSession.default.fakeOutbox.filter { $0.action == "tvState" }.count
        for level in 1...5 {
            socket.fakeDeliver(tvVolume(level: UInt64(level), max: 100))
            await sleepMs(5)
        }
        await sleepMs(300)
        let pushes = WCSession.default.fakeOutbox.filter { $0.action == "tvState" }
        let new = pushes.count - before
        check(new >= 1 && new <= 2, "5 changes in about 25 ms gave \(new) pushes")
        check(pushes.allSatisfy { $0.replyHandler == nil }, "tvState goes with a nil reply handler")
        let last = (pushes.last?.message["state"] as? [String: Any]).flatMap { TVStatus(wire: $0) }
        check(last?.volumeLevel == 5, "latest wins, got \(String(describing: last?.volumeLevel))")
        check(last?.volumeMax == 100)
        check(last?.phase == .connected(.viaPhone))
        m.disconnect()
    }

    await test("relay.tvState.rateCapped") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        WCSession.default.fakeSetReachable(true, notify: false)
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        await sleepMs(250)
        let socket = NWConnection.fakeAll[0]
        let before = WCSession.default.fakeOutbox.filter { $0.action == "tvState" }.count
        let start = Date()
        for level in 1...25 {
            socket.fakeDeliver(tvVolume(level: UInt64(level), max: 100))
            await sleepMs(20)
        }
        let elapsed = Date().timeIntervalSince(start)
        await sleepMs(250)
        let pushes = WCSession.default.fakeOutbox.filter { $0.action == "tvState" }
        let new = pushes.count - before
        let cap = Int(elapsed * 10) + 2
        check(new >= 2 && new <= cap, "\(new) pushes in \(elapsed)s, cap \(cap)")
        let last = (pushes.last?.message["state"] as? [String: Any]).flatMap { TVStatus(wire: $0) }
        check(last?.volumeLevel == 25, "latest wins, got \(String(describing: last?.volumeLevel))")
        m.disconnect()
    }

    await test("relay.tvState.onlyWhenReachable") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        WCSession.default.fakeSetReachable(false, notify: false)
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        await sleepMs(250)
        check(WCSession.default.fakeOutbox.isEmpty, "pushed while unreachable: \(WCSession.default.fakeOutbox.count)")
        WCSession.default.fakeSetReachable(true)
        check(await until(1) { !WCSession.default.fakeOutbox.isEmpty }, "becoming reachable must push the current state")
        m.disconnect()
    }

    await test("relay.tvState.notActivated") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        WCSession.default.fakeSetReachable(true, notify: false)
        WCSession.default.fakeSetActivation(.notActivated)
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        await sleepMs(250)
        check(WCSession.default.fakeOutbox.isEmpty)
        WCSession.default.fakeSetActivation(.activated)
        m.disconnect()
    }

    await test("relay.tvState.phasesReachWatch") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        WCSession.default.fakeSetReachable(true, notify: false)
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        await sleepMs(200)
        defaultBehavior = .tlsReject
        NWConnection.fakeAll[0].fakeDeliver(nil, isComplete: true)
        check(await until(4) { m.phase == .failed(.needsPairing) }, "\(m.phase)")
        await sleepMs(200)
        let phases = WCSession.default.fakeOutbox.compactMap { ($0.message["state"] as? [String: Any]).flatMap { TVStatus(wire: $0)?.phase } }
        check(phases.contains(.reconnecting), "\(phases)")
        check(phases.last == .failed(.needsPairing), "\(phases)")
        m.disconnect()
    }

    await test("relay.deviceListSync") {
        let m = makeManager([])
        let before = WCSession.default.fakeContextUpdates
        m.addPairedDevice(tvA)
        check(WCSession.default.fakeContextUpdates == before + 1, "add must sync")
        let ctx = WCSession.default.applicationContext
        check((ctx["pairedDevices"] as? [[String: Any]])?.count == 1)
        check(ctx["privateKeyData"] != nil && ctx["certificateData"] != nil)
        m.removePairedDevice(tvA)
        check(WCSession.default.fakeContextUpdates == before + 2, "remove must sync")
        check((WCSession.default.applicationContext["pairedDevices"] as? [[String: Any]])?.isEmpty == true)
    }
}
