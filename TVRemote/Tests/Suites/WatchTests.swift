import Foundation
import Network
import WatchConnectivity

func makeWatch(reachable: Bool = true, certificate: Bool = true, devices: [TVDevice] = [tvA, tvB]) -> WatchSessionManager {
    UserDefaults.standard.removeObject(forKey: "watch_paired_devices")
    UserDefaults.standard.removeObject(forKey: "watch_last_device_id")
    WCSession.default.fakeReset()
    WCSession.default.fakeSetReachable(reachable, notify: false)
    fakeSetIdentityAvailable(certificate)
    let manager = WatchSessionManager()
    manager.pairedDevices = devices
    manager.isPhoneReachable = reachable
    return manager
}

func outbox(_ action: String) -> [FakeOutgoing] {
    WCSession.default.fakeOutbox.filter { $0.action == action }
}

func wire(_ phase: ConnectionPhase, device: TVDevice? = tvA, level: Int? = nil, max: Int? = nil, muted: Bool = false, on: Bool? = nil, app: String = "") -> [String: Any] {
    var status = TVStatus()
    status.phase = phase
    status.deviceId = device?.id
    status.volumeLevel = level
    status.volumeMax = max
    status.isMuted = muted
    status.isOn = on
    status.appPackage = app
    return status.wirePayload
}

func push(_ payload: [String: Any], phoneInUse: Bool = false) {
    WCSession.default.fakeIncoming(["action": "tvState", "state": payload, "phoneInUse": phoneInUse], reply: nil)
}

func connected(_ w: WatchSessionManager, _ tv: TVDevice = tvA) async {
    w.connect(to: tv)
    check(await until { !outbox("connect").isEmpty })
    outbox("connect").last?.reply(["status": "connected", "state": wire(.connected(.direct), device: tv)])
    check(await until { w.status.phase == .connected(.viaPhone) }, "\(w.status.phase)")
}

func runWatchTests() async {
    print("### WatchSessionManager tests")

    await test("watch.phone.connectReply") {
        installScriptedTV(.online)
        let w = makeWatch()
        w.connect(to: tvA)
        check(w.status.phase == .connecting, "\(w.status.phase)")
        check(w.activeDevice?.id == tvA.id)
        await settle()
        let sent = outbox("connect")
        check(sent.count == 1)
        check(sent.first?.message["deviceId"] as? String == tvA.id)
        check(sent.first?.replyHandler != nil, "always with a reply handler")
        check(NWConnection.fakeAll.isEmpty, "no direct socket while the phone is reachable")
        sent.first?.reply(["status": "connected", "state": wire(.connected(.direct), level: 24, max: 100, muted: true, on: true, app: "com.netflix.ninja")])
        check(await until { w.status.phase == .connected(.viaPhone) }, "\(w.status.phase)")
        check(w.status.volumeLevel == 24 && w.status.volumeMax == 100 && w.status.isMuted)
        check(w.status.isOn == true)
        check(w.status.appName == "Netflix")
        check(w.status.deviceId == tvA.id)
    }

    await test("watch.phone.connectFailureShapes") {
        installScriptedTV(.online)
        let w = makeWatch()
        w.connect(to: tvA)
        check(await until { !outbox("connect").isEmpty })
        outbox("connect")[0].reply(["status": "error", "failure": ConnectionFailure.needsPairing.rawValue, "message": "x"])
        check(await until { w.status.phase == .failed(.needsPairing) }, "\(w.status.phase)")

        w.retry()
        check(await until { outbox("connect").count == 2 })
        outbox("connect")[1].reply(["status": "error", "message": "no failure key"])
        check(await until { w.status.phase == .failed(.tvUnreachable) }, "a bare error still fails, \(w.status.phase)")

        w.retry()
        check(await until { outbox("connect").count == 3 })
        outbox("connect")[2].reply(["unexpected": true])
        check(await until { w.status.phase == .failed(.tvUnreachable) }, "\(w.status.phase)")
    }

    await test("watch.phone.connectErrorHandler") {
        installScriptedTV(.online)
        let w = makeWatch()
        w.connect(to: tvA)
        check(await until { !outbox("connect").isEmpty })
        outbox("connect")[0].fail(WCError(.messageReplyTimedOut))
        check(await until { w.status.phase == .failed(.timeout) }, "\(w.status.phase)")
        // The phone got there in the end. Its push revives the screen.
        push(wire(.connected(.direct), level: 3, max: 10))
        check(await until { w.status.phase == .connected(.viaPhone) }, "\(w.status.phase)")
        check(w.status.volumeLevel == 3)

        w.disconnect()
        w.connect(to: tvA)
        check(await until { outbox("connect").count == 2 })
        WCSession.default.fakeSetReachable(false, notify: false)
        outbox("connect")[1].fail(WCError(.notReachable))
        check(await until { w.status.phase.failure != nil }, "\(w.status.phase)")
        check(w.status.phase == .failed(.phoneUnreachable), "\(w.status.phase)")
    }

    await test("watch.stale.connectReplyAfterDisconnect") {
        installScriptedTV(.online)
        let w = makeWatch()
        w.connect(to: tvA)
        check(await until { !outbox("connect").isEmpty })
        let pending = outbox("connect")[0]
        w.disconnect()
        check(w.status.phase == .idle)
        check(w.activeDevice == nil)
        pending.reply(["status": "connected", "state": wire(.connected(.direct), level: 9, max: 10)])
        await settle()
        check(w.status.phase == .idle, "stale success after disconnect: \(w.status.phase)")
        check(w.activeDevice == nil)
        check(w.status.volumeLevel == nil)
    }

    await test("watch.stale.failureAfterDisconnect") {
        installScriptedTV(.online)
        let w = makeWatch()
        w.connect(to: tvA)
        check(await until { !outbox("connect").isEmpty })
        let pending = outbox("connect")[0]
        w.disconnect()
        pending.reply(["status": "error", "failure": ConnectionFailure.tvUnreachable.rawValue])
        await settle()
        check(w.status.phase == .idle, "stale failure after disconnect: \(w.status.phase)")
    }

    await test("watch.stale.replyFromOlderAttempt") {
        installScriptedTV(.online)
        let w = makeWatch()
        w.connect(to: tvA)
        check(await until { !outbox("connect").isEmpty })
        let older = outbox("connect")[0]
        w.connect(to: tvB)
        check(await until { outbox("connect").count == 2 })
        check(w.activeDevice?.id == tvB.id)
        older.reply(["status": "connected", "state": wire(.connected(.direct), device: tvA, level: 1, max: 10)])
        await settle()
        check(w.status.phase == .connecting, "\(w.status.phase)")
        check(w.status.volumeLevel == nil, "A's reading on B")
        outbox("connect")[1].reply(["status": "connected", "state": wire(.connected(.direct), device: tvB, level: 2, max: 10)])
        check(await until { w.status.phase == .connected(.viaPhone) })
        check(w.status.volumeLevel == 2)
        check(w.status.deviceId == tvB.id)
    }

    await test("watch.stale.tvStateAfterDisconnect") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        w.disconnect()
        push(wire(.connected(.direct), level: 9, max: 10))
        await settle()
        check(w.status.phase == .idle, "\(w.status.phase)")
        check(w.activeDevice == nil)
    }

    await test("watch.stale.commandReplyAfterDisconnect") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        check(w.send(.ok))
        check(await until { !outbox("command").isEmpty })
        let pending = outbox("command")[0]
        w.disconnect()
        pending.reply(["status": "error", "failure": ConnectionFailure.tvUnreachable.rawValue])
        await settle()
        check(w.status.phase == .idle, "\(w.status.phase)")
        check(w.commandFailureCount == 0, "stale reply must not buzz, \(w.commandFailureCount)")
    }

    await test("watch.disconnect.tellsPhoneOnlyOnPhoneRoute") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        w.disconnect()
        check(await until { !outbox("disconnect").isEmpty }, "phone route must tell the phone")
        check(outbox("disconnect")[0].replyHandler != nil, "always with a reply handler")
    }

    await test("watch.tvState.applied") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        push(wire(.connected(.direct), level: 40, max: 100, muted: true, on: false, app: "com.spotify.tv.android"))
        check(await until { w.status.volumeLevel == 40 })
        check(w.status.isMuted)
        check(w.status.isOn == false && w.status.isTVOff)
        check(w.status.appName == "Spotify")
        check(w.status.phase == .connected(.viaPhone))

        push(wire(.reconnecting))
        check(await until { w.status.phase == .reconnecting }, "\(w.status.phase)")
        check(w.status.volumeLevel == 40, "last reading stays through a reconnect")

        push(wire(.failed(.tvUnreachable)))
        check(await until { w.status.phase == .failed(.tvUnreachable) }, "\(w.status.phase)")

        push(wire(.connected(.direct), level: 41, max: 100))
        check(await until { w.status.phase == .connected(.viaPhone) }, "the phone came back on its own")
        check(w.status.volumeLevel == 41)
    }

    await test("watch.tvState.withReplyHandlerVariant") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        var replies = 0
        WCSession.default.fakeIncoming(["action": "tvState", "state": wire(.connected(.direct), level: 2, max: 9)]) { _ in replies += 1 }
        check(await until { w.status.volumeLevel == 2 })
        check(await until { replies == 1 }, "every reply-variant path must reply")
        WCSession.default.fakeIncoming(["action": "nope"]) { _ in replies += 1 }
        check(await until { replies == 2 }, "unknown action must still reply")
    }

    await test("watch.tvState.staleFailureDuringConnect") {
        installScriptedTV(.online)
        let w = makeWatch()
        w.connect(to: tvA)
        check(await until { !outbox("connect").isEmpty })
        push(wire(.failed(.tvUnreachable)))
        await settle()
        check(w.status.phase == .connecting, "the reply is the verdict, got \(w.status.phase)")
        outbox("connect")[0].reply(["status": "connected"])
        check(await until { w.status.phase == .connected(.viaPhone) })
    }

    await test("watch.tvState.backgroundIdleAlwaysReclaims") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        // The phone went to the background and dropped the TV.
        push(wire(.idle, device: nil))
        check(await until { outbox("connect").count == 2 }, "should ask once more")
        check(w.status.phase == .connecting, "\(w.status.phase)")
        outbox("connect")[1].reply(["status": "connected"])
        check(await until { w.status.phase == .connected(.viaPhone) })
        // A routine background drop soon after is not two clients fighting.
        push(wire(.idle, device: nil))
        check(await until { outbox("connect").count == 3 }, "should ask again, \(w.status.phase)")
        check(w.status.phase == .connecting, "must not show Can't Reach TV, \(w.status.phase)")
        outbox("connect")[2].reply(["status": "connected"])
        check(await until { w.status.phase == .connected(.viaPhone) })
    }

    await test("watch.tvState.otherTVReclaimsOnceThenLeaves") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        push(wire(.connected(.direct), device: tvB))
        check(await until { outbox("connect").count == 2 }, "should ask once")
        outbox("connect")[1].reply(["status": "connected"])
        check(await until { w.status.phase == .connected(.viaPhone) })
        // Again right away: something else wants the phone.
        push(wire(.connected(.direct), device: tvB))
        check(await until { w.activeDevice == nil }, "\(w.status.phase)")
        check(w.status.phase == .idle, "nothing is wrong with the TV, \(w.status.phase)")
        await settle()
        check(outbox("connect").count == 2, "must not fight over the phone")
        check(outbox("disconnect").isEmpty, "the phone is on another TV, leave it alone")
    }

    await test("watch.phoneInUse.disconnectIsRespected") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        push(wire(.idle, device: nil), phoneInUse: true)
        check(await until { w.activeDevice == nil }, "\(w.status.phase)")
        check(w.status.phase == .idle, "\(w.status.phase)")
        await settle()
        check(outbox("connect").count == 1, "must not undo Disconnect on the phone")
        check(outbox("disconnect").isEmpty)
        check(UserDefaults.standard.string(forKey: "watch_last_device_id") == nil, "a later wrist raise must not undo it either")
    }

    await test("watch.phoneInUse.switchIsRespected") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        push(wire(.connecting, device: tvB), phoneInUse: true)
        check(await until { w.activeDevice == nil }, "\(w.status.phase)")
        await settle()
        check(outbox("connect").count == 1, "must not pull the phone back")
        check(outbox("disconnect").isEmpty)
    }

    await test("watch.phoneInUse.viaPoll") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        w.appDidBecomeActive()
        check(await until { !outbox("getState").isEmpty })
        outbox("getState")[0].reply(["state": wire(.idle, device: nil), "phoneInUse": true])
        check(await until { w.activeDevice == nil }, "\(w.status.phase)")
        check(outbox("connect").count == 1)
    }

    await test("watch.phoneInUse.connectInFlightStillDecidedByReply") {
        installScriptedTV(.online)
        let w = makeWatch()
        w.connect(to: tvA)
        check(await until { !outbox("connect").isEmpty })
        push(wire(.connected(.direct), device: tvB), phoneInUse: true)
        await settle()
        check(w.activeDevice?.id == tvA.id)
        outbox("connect")[0].reply(["status": "connected"])
        check(await until { w.status.phase == .connected(.viaPhone) })
    }

    await test("watch.poll.timeoutKeepsRemote") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        w.appDidBecomeActive()
        check(await until { !outbox("getState").isEmpty })
        outbox("getState")[0].fail(WCError(.messageReplyTimedOut))
        await settle()
        check(w.status.phase == .connected(.viaPhone), "a slow phone is not a missing phone, \(w.status.phase)")
        w.appDidBecomeActive()
        check(await until { outbox("getState").count == 2 })
        outbox("getState")[1].fail(WCError(.notReachable))
        check(await until { w.status.phase == .failed(.phoneUnreachable) }, "\(w.status.phase)")
    }

    await test("watch.needsPairing.refreshesList") {
        installScriptedTV(.online)
        let w = makeWatch()
        w.connect(to: tvA)
        check(await until { !outbox("connect").isEmpty })
        let before = outbox("getDevices").count
        outbox("connect")[0].reply(["status": "error", "failure": ConnectionFailure.needsPairing.rawValue, "message": "Device not found"])
        check(await until { outbox("getDevices").count == before + 1 }, "should ask whether the TV still exists")
        check(w.status.phase == .failed(.needsPairing), "\(w.status.phase)")
        let list: [[String: Any]] = [["id": tvB.id, "name": tvB.name, "host": tvB.host, "port": tvB.port, "isPaired": true]]
        outbox("getDevices").last?.reply(["devices": list])
        check(await until { w.activeDevice == nil }, "a removed TV must not stay on Pair Again, \(w.status.phase)")
        check(w.status.phase == .idle, "\(w.status.phase)")
    }

    await test("watch.needsPairing.stillListedKeepsFailed") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        check(w.send(.ok))
        check(await until { !outbox("command").isEmpty })
        let before = outbox("getDevices").count
        outbox("command")[0].reply(["status": "error", "failure": ConnectionFailure.needsPairing.rawValue])
        check(await until { outbox("getDevices").count == before + 1 })
        let list: [[String: Any]] = [["id": tvA.id, "name": tvA.name, "host": tvA.host, "port": tvA.port, "isPaired": true]]
        outbox("getDevices").last?.reply(["devices": list])
        await settle()
        check(w.status.phase == .failed(.needsPairing), "\(w.status.phase)")
        check(w.activeDevice?.id == tvA.id)
    }

    await test("watch.commandRejected") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        WCSession.default.fakeIncoming(["action": "commandRejected"], reply: nil)
        check(await until { w.commandFailureCount == 1 }, "\(w.commandFailureCount)")
        check(w.status.phase == .connected(.viaPhone), "\(w.status.phase)")
    }

    await test("watch.commandRejected.direct") {
        installScriptedTV(.online)
        let w = makeWatch(reachable: false)
        w.connect(to: tvA)
        check(await until { w.status.phase == .connected(.direct) })
        NWConnection.fakeAll[0].fakeDeliver(tvError())
        check(await until { w.commandFailureCount == 1 }, "\(w.commandFailureCount)")
        check(w.status.phase == .connected(.direct), "\(w.status.phase)")
    }

    await test("watch.command.okAndState") {
        installScriptedTV(.online)
        let w = makeWatch()
        check(!w.send(.ok), "no active device")
        await connected(w)
        check(w.send(.volumeUp))
        check(await until { !outbox("command").isEmpty })
        let sent = outbox("command")[0]
        check(sent.message["command"] as? String == "volumeUp")
        check(sent.message["deviceId"] as? String == tvA.id)
        check(sent.replyHandler != nil)
        sent.reply(["status": "ok", "state": wire(.connected(.direct), level: 25, max: 100)])
        check(await until { w.status.volumeLevel == 25 })
        check(w.commandFailureCount == 0)
    }

    await test("watch.command.failureBumpsCount") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        check(w.send(.ok))
        check(await until { !outbox("command").isEmpty })
        outbox("command")[0].reply(["status": "error", "failure": ConnectionFailure.timeout.rawValue, "message": "x"])
        check(await until { w.commandFailureCount == 1 }, "\(w.commandFailureCount)")
        check(await until { w.status.phase == .failed(.timeout) }, "\(w.status.phase)")
    }

    await test("watch.command.errorHandlerBumpsCount") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        check(w.send(.ok))
        check(await until { !outbox("command").isEmpty })
        outbox("command")[0].fail(WCError(.messageReplyTimedOut))
        check(await until { w.commandFailureCount == 1 })
        await settle()
        check(w.status.phase == .connected(.viaPhone), "one timed-out press is not a lost session, \(w.status.phase)")
    }

    await test("watch.direct.unreachableUsesCertificate") {
        installScriptedTV(.online)
        let w = makeWatch(reachable: false)
        w.connect(to: tvA)
        check(await until { w.status.phase == .connected(.direct) }, "\(w.status.phase)")
        check(outbox("connect").isEmpty, "must not ask the phone while on direct")
        check(NWConnection.fakeAll.count == 1)
        NWConnection.fakeAll[0].fakeDeliver(tvVolume(level: 8, max: 20))
        check(await until { w.status.volumeLevel == 8 }, "direct readings must reach status")
        check(w.send(.ok))
        check(NWConnection.fakeAll[0].fakeSent.last == RemoteProtocol.keyInject(keyCode: 23))
        check(outbox("command").isEmpty)
        w.disconnect()
        check(await until { NWConnection.fakeAll[0].fakeCancelCount >= 1 })
        check(outbox("disconnect").isEmpty, "direct route has nothing to tell the phone")
    }

    await test("watch.direct.tn3135Waiting") {
        installScriptedTV(.networkDown)
        let w = makeWatch(reachable: false)
        let start = Date()
        w.connect(to: tvA)
        check(await until(2) { w.status.phase.failure != nil }, "\(w.status.phase)")
        check(Date().timeIntervalSince(start) < 1, "must fail fast on .waiting")
        check(w.status.phase == .failed(.phoneUnreachable), "\(w.status.phase)")
        check(outbox("connect").isEmpty)
    }

    await test("watch.direct.needsPairingWins") {
        installScriptedTV(.tlsReject)
        let w = makeWatch(reachable: false)
        w.connect(to: tvA)
        check(await until(2) { w.status.phase.failure != nil }, "\(w.status.phase)")
        check(w.status.phase == .failed(.needsPairing), "\(w.status.phase)")
    }

    await test("watch.direct.noCertificate") {
        installScriptedTV(.online)
        let w = makeWatch(reachable: false, certificate: false)
        w.connect(to: tvA)
        check(w.status.phase == .failed(.phoneUnreachable), "\(w.status.phase)")
        check(NWConnection.fakeAll.isEmpty)
        check(outbox("connect").isEmpty)
    }

    await test("watch.direct.staleAfterDisconnect") {
        installScriptedTV(.silent)
        let w = makeWatch(reachable: false)
        w.connect(to: tvA)
        check(await until { NWConnection.fakeAll.count == 1 })
        let socket = NWConnection.fakeAll[0]
        w.disconnect()
        handshake(socket)
        await settle()
        check(w.status.phase == .idle, "\(w.status.phase)")
        check(w.activeDevice == nil)
    }

    await test("watch.direct.lostRetriesThenFails") {
        installScriptedTV(.online)
        let w = makeWatch(reachable: false)
        w.connect(to: tvA)
        check(await until { w.status.phase == .connected(.direct) })
        defaultBehavior = .networkDown
        let start = Date()
        NWConnection.fakeAll[0].fakeDeliver(nil, isComplete: true)
        check(await until { w.status.phase == .reconnecting }, "\(w.status.phase)")
        check(await until(30) { w.status.phase.failure != nil }, "\(w.status.phase)")
        let elapsed = Date().timeIntervalSince(start)
        check(w.status.phase == .failed(.phoneUnreachable), "\(w.status.phase)")
        check(NWConnection.fakeAll.count == 1 + 5, "got \(NWConnection.fakeAll.count - 1) retries")
        check(elapsed >= 22 && elapsed < 26, "took \(elapsed)")
        let count = NWConnection.fakeAll.count
        await sleepMs(2000)
        check(NWConnection.fakeAll.count == count, "kept retrying past the budget")
    }

    await test("watch.reachability.phoneLeavesAndReturns") {
        installScriptedTV(.networkDown)
        let w = makeWatch()
        await connected(w)
        WCSession.default.fakeSetReachable(false)
        check(await until { w.status.phase == .failed(.phoneUnreachable) }, "\(w.status.phase)")
        check(NWConnection.fakeAll.count == 1, "tries direct once, \(NWConnection.fakeAll.count)")
        WCSession.default.fakeSetReachable(true)
        check(await until { outbox("connect").count == 2 }, "phone back: go through it again")
        check(w.status.phase == .connecting, "\(w.status.phase)")
        outbox("connect")[1].reply(["status": "connected"])
        check(await until { w.status.phase == .connected(.viaPhone) })
    }

    await test("watch.reachability.noCertificate") {
        installScriptedTV(.online)
        let w = makeWatch(certificate: false)
        await connected(w)
        WCSession.default.fakeSetReachable(false)
        check(await until { w.status.phase == .failed(.phoneUnreachable) }, "\(w.status.phase)")
        check(NWConnection.fakeAll.isEmpty)
    }

    await test("watch.reachability.directHandsBackToPhone") {
        installScriptedTV(.online)
        let w = makeWatch(reachable: false)
        w.connect(to: tvA)
        check(await until { w.status.phase == .connected(.direct) })
        // A live direct session stays: the TV takes one client and this one works.
        WCSession.default.fakeSetReachable(true)
        await settle()
        check(w.status.phase == .connected(.direct), "\(w.status.phase)")
        check(outbox("connect").isEmpty, "must not make the phone fight a working session")
        // Once that session dies, the phone is the route.
        NWConnection.fakeAll[0].fakeDeliver(nil, isComplete: true)
        check(await until { !outbox("connect").isEmpty }, "\(w.status.phase)")
        check(w.status.phase == .connecting, "\(w.status.phase)")
    }

    await test("watch.lifecycle.resumeWithPhone") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        w.appDidResignActive()
        w.appDidBecomeActive()
        check(await until { !outbox("getState").isEmpty }, "should re-read state from the phone")
        check(await until { !outbox("getDevices").isEmpty })
        outbox("getState")[0].reply(["state": wire(.connected(.direct), level: 55, max: 100)])
        check(await until { w.status.volumeLevel == 55 }, "\(String(describing: w.status.volumeLevel))")
        check(outbox("connect").count == 1, "must not reconnect a healthy route")
    }

    await test("watch.lifecycle.resumeLastDevice") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w, tvB)
        // A new launch finds the id saved by the last one.
        let saved = UserDefaults.standard.string(forKey: "watch_last_device_id")
        check(saved == tvB.id)
        let next = WatchSessionManager()
        next.pairedDevices = [tvA, tvB]
        let before = outbox("connect").count
        let statesBefore = outbox("getState").count
        next.appDidBecomeActive()
        check(await until { outbox("getState").count == statesBefore + 1 }, "should look before taking the phone")
        check(outbox("connect").count == before, "nobody tapped anything, so ask first")
        outbox("getState").last?.reply(["state": wire(.idle, device: nil), "phoneInUse": true])
        check(await until { outbox("connect").count == before + 1 }, "an idle phone is free, resume the last TV")
        check(outbox("connect").last?.message["deviceId"] as? String == tvB.id)
    }

    await test("watch.lifecycle.launchLeavesPhoneInUse") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w, tvB)
        let next = WatchSessionManager()
        next.pairedDevices = [tvA, tvB]
        let before = outbox("connect").count
        let statesBefore = outbox("getState").count
        next.appDidBecomeActive()
        check(await until { outbox("getState").count == statesBefore + 1 })
        outbox("getState").last?.reply(["state": wire(.connected(.direct), device: tvA), "phoneInUse": true])
        await settle()
        check(outbox("connect").count == before, "raising a wrist must not take the phone off its TV")
        check(next.activeDevice == nil)
        check(next.status.phase == .idle, "\(next.status.phase)")
        check(UserDefaults.standard.string(forKey: "watch_last_device_id") == tvB.id, "stays for the next launch")
    }

    await test("watch.lifecycle.launchTakesBackgroundedPhone") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w, tvB)
        let next = WatchSessionManager()
        next.pairedDevices = [tvA, tvB]
        let before = outbox("connect").count
        let statesBefore = outbox("getState").count
        next.appDidBecomeActive()
        check(await until { outbox("getState").count == statesBefore + 1 })
        outbox("getState").last?.reply(["state": wire(.connected(.direct), device: tvA), "phoneInUse": false])
        check(await until { outbox("connect").count == before + 1 }, "nobody is at the phone")
        check(next.activeDevice?.id == tvB.id)
    }

    await test("watch.lifecycle.launchAnswersForSameTV") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w, tvB)
        let next = WatchSessionManager()
        next.pairedDevices = [tvA, tvB]
        let before = outbox("connect").count
        let statesBefore = outbox("getState").count
        next.appDidBecomeActive()
        check(await until { outbox("getState").count == statesBefore + 1 })
        outbox("getState").last?.reply(["state": wire(.connected(.direct), device: tvB), "phoneInUse": true])
        check(await until { outbox("connect").count == before + 1 }, "already on our TV, the connect just reuses it")
    }

    await test("watch.lifecycle.launchCheckFailureStillConnects") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w, tvB)
        let next = WatchSessionManager()
        next.pairedDevices = [tvA, tvB]
        let before = outbox("connect").count
        let statesBefore = outbox("getState").count
        next.appDidBecomeActive()
        check(await until { outbox("getState").count == statesBefore + 1 })
        outbox("getState").last?.fail(WCError(.messageReplyTimedOut))
        check(await until { outbox("connect").count == before + 1 })
    }

    await test("watch.lifecycle.tapDuringLaunchCheckWins") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w, tvB)
        let next = WatchSessionManager()
        next.pairedDevices = [tvA, tvB]
        let before = outbox("connect").count
        let statesBefore = outbox("getState").count
        next.appDidBecomeActive()
        check(await until { outbox("getState").count == statesBefore + 1 })
        let pending = outbox("getState").last
        next.connect(to: tvA)
        check(await until { outbox("connect").count == before + 1 })
        pending?.reply(["state": wire(.idle, device: nil), "phoneInUse": false])
        await settle()
        check(outbox("connect").count == before + 1, "a stale check must not connect again")
        check(next.activeDevice?.id == tvA.id)
    }

    await test("watch.lifecycle.launchUnreachableThenPhoneInUse") {
        installScriptedTV(.networkDown)
        let w = makeWatch()
        await connected(w, tvB)
        let next = WatchSessionManager()
        next.pairedDevices = [tvA, tvB]
        WCSession.default.fakeSetReachable(false, notify: false)
        next.isPhoneReachable = false
        let before = outbox("connect").count
        let statesBefore = outbox("getState").count
        next.appDidBecomeActive()
        check(await until { next.status.phase == .failed(.phoneUnreachable) }, "\(next.status.phase)")
        WCSession.default.fakeSetReachable(true)
        check(await until { outbox("getState").count > statesBefore }, "should look before taking the phone")
        check(outbox("connect").count == before)
        outbox("getState").last?.reply(["state": wire(.connected(.direct), device: tvA), "phoneInUse": true])
        check(await until { next.activeDevice == nil }, "\(next.status.phase)")
        await settle()
        check(outbox("connect").count == before, "reachability arriving late must not take the phone either")
    }

    await test("watch.lifecycle.launchUnreachableThenPhoneFree") {
        installScriptedTV(.networkDown)
        let w = makeWatch()
        await connected(w, tvB)
        let next = WatchSessionManager()
        next.pairedDevices = [tvA, tvB]
        WCSession.default.fakeSetReachable(false, notify: false)
        next.isPhoneReachable = false
        let before = outbox("connect").count
        let statesBefore = outbox("getState").count
        next.appDidBecomeActive()
        check(await until { next.status.phase == .failed(.phoneUnreachable) }, "\(next.status.phase)")
        WCSession.default.fakeSetReachable(true)
        check(await until { outbox("getState").count > statesBefore })
        outbox("getState").last?.reply(["state": wire(.idle, device: nil), "phoneInUse": false])
        check(await until { outbox("connect").count == before + 1 }, "\(next.status.phase)")
        check(next.status.phase == .connecting, "\(next.status.phase)")
    }

    await test("watch.reachability.tappedTVIsNotChecked") {
        installScriptedTV(.networkDown)
        let w = makeWatch(reachable: false)
        w.connect(to: tvA)
        check(await until { w.status.phase == .failed(.phoneUnreachable) }, "\(w.status.phase)")
        let statesBefore = outbox("getState").count
        WCSession.default.fakeSetReachable(true)
        check(await until { !outbox("connect").isEmpty }, "the user asked for this TV")
        check(outbox("getState").count == statesBefore, "no check needed")
    }

    await test("watch.lifecycle.beforeActivation") {
        installScriptedTV(.online)
        let w = makeWatch()
        WCSession.default.fakeSetActivation(.notActivated)
        // None of these may send on an inactive session, which would be a programmer error.
        w.requestDevices()
        w.appDidBecomeActive()
        w.connect(to: tvA)
        check(await until(1) { w.status.phase == .connected(.direct) || w.status.phase.failure != nil }, "\(w.status.phase)")
        w.disconnect()
        check(WCSession.default.fakeOutbox.isEmpty, "\(WCSession.default.fakeOutbox.count) sent on an inactive session")
        WCSession.default.fakeSetActivation(.activated)
    }

    await test("watch.context.removedDeviceDisconnects") {
        installScriptedTV(.online)
        let w = makeWatch()
        await connected(w)
        let list: [[String: Any]] = [["id": tvB.id, "name": tvB.name, "host": tvB.host, "port": tvB.port, "isPaired": true]]
        WCSession.default.fakeIncomingContext(["pairedDevices": list])
        check(await until { w.activeDevice == nil }, "active TV was removed on the iPhone")
        check(w.status.phase == .idle, "\(w.status.phase)")
        check(w.pairedDevices.map(\.id) == [tvB.id])
    }

    await test("watch.context.importsCertificateBeforeList") {
        installScriptedTV(.online)
        let w = makeWatch(reachable: false, certificate: false)
        check(!w.hasCertificate)
        let list: [[String: Any]] = [["id": tvA.id, "name": tvA.name, "host": tvA.host, "port": tvA.port, "isPaired": true]]
        WCSession.default.fakeIncomingContext(["pairedDevices": list, "privateKeyData": Data([1]), "certificateData": Data([2])])
        check(await until { w.hasCertificate }, "hasCertificate must update")
        check(w.pairedDevices.count == 1)
    }
}
