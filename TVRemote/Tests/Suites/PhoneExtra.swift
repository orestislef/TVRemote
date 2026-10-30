import Foundation
import Network
import UIKit
import WatchConnectivity

func pairingOK() -> Data {
    var message = ProtobufEncoder()
    message.addVarint(field: 1, value: 2)
    message.addVarint(field: 2, value: 200)
    return MessageFraming.frame(message.encoded)
}

func startPair(_ pairing: AndroidTVPairing, _ tv: TVDevice) -> Task<Error?, Never> {
    Task { @MainActor in
        do {
            try await pairing.startPairing(device: tv)
            return nil
        } catch {
            return error
        }
    }
}

func toPIN(_ pairing: AndroidTVPairing, _ tv: TVDevice) async -> NWConnection {
    let count = NWConnection.fakeAll.count
    let task = startPair(pairing, tv)
    let socket = await nextSocket(after: count)
    socket.fakeSetState(.ready)
    for _ in 0..<3 {
        socket.fakeDeliver(pairingOK())
        await sleepMs(10)
    }
    let error = await task.value
    check(error == nil, "pairing to PIN failed: \(String(describing: error))")
    check(pairing.state == .waitingForCode, "\(pairing.state)")
    return socket
}

func sockaddrData(ip: String, port: UInt16) -> Data {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    _ = inet_pton(AF_INET, ip, &address.sin_addr)
    return withUnsafeBytes(of: &address) { Data($0) }
}

func runExtraPhoneTests() async {
    print("### pairing tests")

    await test("pair.toPIN") {
        let pairing = AndroidTVPairing()
        let socket = await toPIN(pairing, tvA)
        check(socket.fakeSent.count == 3, "request, option, configuration, got \(socket.fakeSent.count)")
        check(socket.fakeParameters.includePeerToPeer)
        pairing.cancel()
        check(pairing.state == .idle)
    }

    await test("pair.noDoubleResume.failedThenCancelled") {
        let pairing = AndroidTVPairing()
        let task = startPair(pairing, tvA)
        let first = await nextSocket(after: 0)
        first.fakeSetState(.failed(.tls(-9808)))
        first.fakeSetState(.cancelled)
        let second = await nextSocket(after: 1)
        first.fakeFireStaleHandler(.cancelled)
        second.fakeSetState(.failed(.posix(.ECONNREFUSED)))
        second.fakeSetState(.cancelled)
        let error = await task.value
        check(error != nil)
        check(pairing.state == .failed, "\(pairing.state)")
        check(NWConnection.fakeAll.count == 2, "two attempts, got \(NWConnection.fakeAll.count)")
        check(first.fakeCancelCount >= 1)
        check(second.fakeCancelCount >= 1)
    }

    await test("pair.waitingFailsFast") {
        let pairing = AndroidTVPairing()
        let start = Date()
        let task = startPair(pairing, tvA)
        let first = await nextSocket(after: 0)
        first.fakeSetState(.waiting(.posix(.ENETUNREACH)))
        let second = await nextSocket(after: 1)
        second.fakeSetState(.waiting(.posix(.ENETUNREACH)))
        let error = await task.value
        check(error != nil)
        check(pairing.state == .failed, "\(pairing.state)")
        check(Date().timeIntervalSince(start) < 2, "spun on .waiting")
    }

    await test("pair.cancelDuringOpenStopsRetrying") {
        let pairing = AndroidTVPairing()
        let task = startPair(pairing, tvA)
        let socket = await nextSocket(after: 0)
        pairing.cancel()
        let error = await task.value
        check(error != nil)
        check(pairing.state == .idle, "\(pairing.state)")
        await sleepMs(1500)
        check(NWConnection.fakeAll.count == 1, "a cancelled flow opened \(NWConnection.fakeAll.count) sockets, TV would show a PIN to nobody")
        check(pairing.state == .idle, "\(pairing.state)")
        check(socket.fakeCancelCount >= 1)
    }

    await test("pair.openTimeout") {
        let pairing = AndroidTVPairing()
        let start = Date()
        let error = await startPair(pairing, tvA).value
        let elapsed = Date().timeIntervalSince(start)
        check(error != nil)
        check(pairing.state == .failed, "\(pairing.state)")
        check(NWConnection.fakeAll.count == 2)
        check(elapsed >= 20 && elapsed < 23, "took \(elapsed)")
    }

    await test("pair.eofAtPIN") {
        let pairing = AndroidTVPairing()
        let socket = await toPIN(pairing, tvA)
        socket.fakeDeliver(nil, isComplete: true)
        check(await until { pairing.state == .failed }, "\(pairing.state)")
        check(pairing.errorMessage == PairingError.closedByTV.errorDescription, "\(String(describing: pairing.errorMessage))")
        check(socket.fakeCancelCount >= 1)
        do {
            try await pairing.submitCode("A1B2C3")
            check(false, "submit on a dead session must throw")
        } catch {}
    }

    await test("pair.badCodeKeepsSession") {
        let pairing = AndroidTVPairing()
        let socket = await toPIN(pairing, tvA)
        for code in ["XYZ123", "ABC", ""] {
            do {
                try await pairing.submitCode(code)
                check(false, "\(code) must throw")
            } catch {
                check(error as? PairingError == nil ? false : true)
            }
            check(pairing.state == .waitingForCode, "bad code '\(code)' left \(pairing.state)")
            check(pairing.errorMessage != nil)
        }
        check(socket.fakeCancelCount == 0, "session must survive a typo")
        pairing.cancel()
    }

    await test("pair.staleTimersDontFire") {
        let pairing = AndroidTVPairing()
        let socket = await toPIN(pairing, tvA)
        await sleepMs(31_000)
        check(pairing.state == .waitingForCode, "a step timer fired during the PIN screen: \(pairing.state)")
        check(socket.fakeCancelCount == 0)
        pairing.cancel()
    }

    await test("pair.startOverCancelsOldSocket") {
        let pairing = AndroidTVPairing()
        let first = await toPIN(pairing, tvA)
        pairing.cancel()
        let second = await toPIN(pairing, tvA)
        check(first !== second)
        check(first.fakeCancelCount >= 1)
        first.fakeFireStaleHandler(.cancelled)
        first.fakeDeliver(nil, isComplete: true)
        await settle()
        check(pairing.state == .waitingForCode, "stale socket hit the new session: \(pairing.state)")
        pairing.cancel()
    }

    print("### background time tests")

    await test("bg.keepAliveExpiry.noWatchClosesSession") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        WCSession.default.fakeSetReachable(true, notify: false)
        m.appDidEnterBackground()
        check(m.phase == .connected(.direct))
        let open = UIApplication.shared.fakeTasks
        check(open.count == 1, "keep-alive task, got \(open.count)")
        WCSession.default.fakeSetReachable(false, notify: false)
        if let expiry = open.values.first, let handler = expiry { handler() }
        check(await until { m.phase == .idle }, "\(m.phase)")
        check(UIApplication.shared.fakeTasks.isEmpty, "background task leaked, iOS would kill the app")
    }

    await test("bg.keepAliveExpiry.watchUpLeavesSession") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        WCSession.default.fakeSetReachable(true, notify: false)
        m.appDidEnterBackground()
        let open = UIApplication.shared.fakeTasks
        if let expiry = open.values.first, let handler = expiry { handler() }
        await settle()
        check(m.phase == .connected(.direct), "\(m.phase)")
        check(UIApplication.shared.fakeTasks.isEmpty, "background task leaked")
        m.appDidBecomeActive()
        check(UIApplication.shared.fakeTasks.isEmpty)
        m.disconnect()
    }

    await test("bg.hold.watchMessageBalanced") {
        installScriptedTV(.online)
        let m = makeManager([tvA], foreground: false)
        _ = await ask(["action": "connect", "deviceId": tvA.id])
        check(UIApplication.shared.fakeTasks.count == 1, "one hold, got \(UIApplication.shared.fakeTasks.count)")
        check(PhoneSessionManager.shared.isHoldingBackgroundTime)
        _ = await ask(["action": "command", "command": "ok", "deviceId": tvA.id])
        check(UIApplication.shared.fakeTasks.count == 1, "a second message must not stack holds")
        let handlers = UIApplication.shared.fakeTasks.values
        if let expiry = handlers.first, let handler = expiry { handler() }
        await settle()
        check(UIApplication.shared.fakeTasks.isEmpty, "hold leaked")
        check(m.phase == .idle, "time up with no Watch: close the socket, \(m.phase)")
    }

    print("### regressions")

    await test("conn.dropSocket.keepsReadings") {
        let rig = Rig()
        let socket = await connectFully(rig, tvA)
        socket.fakeDeliver(tvVolume(level: 24, max: 100, muted: true))
        socket.fakeDeliver(tvApp(label: "Netflix", package: "com.netflix.ninja"))
        check(await until { rig.conn.volumeLevel == 24 && rig.conn.appLabel == "Netflix" })
        rig.conn.dropSocket()
        check(!rig.conn.isConnected)
        check(rig.conn.connectedDeviceId == tvA.id, "status needs the id to keep showing the readings")
        check(rig.conn.volumeLevel == 24 && rig.conn.volumeMax == 100 && rig.conn.volumeMuted)
        check(rig.conn.appLabel == "Netflix")
        check(socket.fakeCancelCount >= 1)
        await settle()
        check(rig.lost.isEmpty, "\(rig.lost)")
        await connectFully(rig, tvA)
        check(rig.conn.volumeLevel == 24)
        let count = NWConnection.fakeAll.count
        let other = startConnect(rig, tvB)
        _ = await nextSocket(after: count)
        check(rig.conn.volumeLevel == nil, "another TV must not inherit them")
        rig.conn.disconnect()
        _ = await other.value
    }

    await test("mgr.background.closedHandshakeRetriesOnceAndStaysRetryable") {
        installScriptedTV(.eofAfterReady)
        let m = makeManager([tvA], foreground: false)
        let start = Date()
        let reply = await ask(["action": "connect", "deviceId": tvA.id], timeout: 8)
        check(reply.status == "error", "\(String(describing: reply.first))")
        check(reply.failure == ConnectionFailure.timeout.rawValue, "a background retry must not claim the pairing is gone, \(String(describing: reply.failure))")
        check(m.phase == .failed(.timeout), "\(m.phase)")
        check(NWConnection.fakeAll.count == 2, "exactly one retry, got \(NWConnection.fakeAll.count) sockets")
        let elapsed = Date().timeIntervalSince(start)
        check(elapsed >= 0.9 && elapsed < 4, "took \(elapsed)")
        // Foregrounding auto-reconnects, which a false needsPairing would have blocked.
        defaultBehavior = .online
        m.appDidBecomeActive()
        check(await until { m.phase == .connected(.direct) }, "\(m.phase)")
        m.disconnect()
    }

    await test("mgr.network.downWhileConnected") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        let monitor = NWPathMonitor.fakeAll.last!
        monitor.fakeUpdate(path(false))
        await sleepMs(1000)
        check(m.phase == .connected(.direct), "must ride out a handoff, \(m.phase)")
        check(await until(2) { m.phase == .failed(.noWiFi) }, "\(m.phase)")
        check(NWConnection.fakeAll[0].fakeCancelCount >= 1)
        monitor.fakeUpdate(path(true))
        check(await until(2) { m.phase == .connected(.direct) }, "network back should retry, \(m.phase)")
        m.disconnect()
    }

    await test("mgr.network.blipKeepsSession") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        let monitor = NWPathMonitor.fakeAll.last!
        monitor.fakeUpdate(path(false))
        await sleepMs(500)
        monitor.fakeUpdate(path(true))
        await sleepMs(2500)
        check(m.phase == .connected(.direct), "\(m.phase)")
        check(NWConnection.fakeAll.count == 1)
        check(NWConnection.fakeAll[0].fakeCancelCount == 0)
        m.disconnect()
    }

    await test("mgr.network.downWhileConnectedInBackground") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        WCSession.default.fakeSetReachable(true, notify: false)
        m.appDidEnterBackground()
        NWPathMonitor.fakeAll.last!.fakeUpdate(path(false))
        check(await until(3) { m.phase == .idle }, "\(m.phase)")
        check(!m.remoteConnection.isConnected)
    }

    await test("mgr.foreground.returnsToIntendedDevice") {
        installScriptedTV(.online)
        let m = makeManager([tvA, tvB])
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        behaviorByHost[tvB.host] = .silent
        m.connect(to: tvB)
        await settle()
        m.appDidEnterBackground()
        check(m.phase == .idle, "\(m.phase)")
        check(m.activeDevice == nil)
        behaviorByHost[tvB.host] = .online
        let before = sockets(to: tvA.host).count
        m.appDidBecomeActive()
        check(await until { m.phase == .connected(.direct) }, "\(m.phase)")
        check(m.activeDevice?.id == tvB.id, "the screen is on B, got \(m.activeDevice?.id ?? "nil")")
        check(sockets(to: tvA.host).count == before, "opened a socket to a TV nobody is looking at")
        m.disconnect()
    }

    await test("mgr.commandRejected") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        WCSession.default.fakeSetReachable(true, notify: false)
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        NWConnection.fakeAll[0].fakeDeliver(tvError())
        check(await until { m.commandRejectionCount == 1 }, "\(m.commandRejectionCount)")
        check(await until { WCSession.default.fakeOutbox.contains { $0.action == "commandRejected" } }, "the Watch must hear of it")
        check(m.phase == .connected(.direct), "\(m.phase)")
        m.disconnect()
    }

    await test("relay.phoneInUse") {
        installScriptedTV(.online)
        let m = makeManager([tvA])
        WCSession.default.fakeSetReachable(true, notify: false)
        let foreground = await ask(["action": "getState"])
        check(foreground.first?["phoneInUse"] as? Bool == true, "\(String(describing: foreground.first))")
        m.connect(to: tvA)
        check(await until { m.phase == .connected(.direct) })
        await sleepMs(200)
        let lastPush = WCSession.default.fakeOutbox.last { $0.action == "tvState" }
        check(lastPush?.message["phoneInUse"] as? Bool == true, "\(String(describing: lastPush?.message))")
        m.appDidEnterBackground()
        let background = await ask(["action": "getState"])
        check(background.first?["phoneInUse"] as? Bool == false, "\(String(describing: background.first))")
        m.disconnect()
    }

    print("### discovery tests")

    await test("disc.resolveAndDrop") {
        let discovery = BonjourDiscovery()
        var seen: [TVDevice] = []
        discovery.onDeviceResolved = { seen.append($0) }
        discovery.startDiscovery()
        check(discovery.isSearching)
        let browser = NWBrowser.fakeAll.last!
        check(browser.fakeStarted)
        NetService.fakeAll = []
        browser.fakeResults(["Living Room"])
        check(await until { !NetService.fakeAll.isEmpty }, "no resolver started")
        let service = NetService.fakeAll[0]
        check(service.name == "Living Room")
        service.port = 6466
        service.addresses = [sockaddrData(ip: "10.0.0.42", port: 6466)]
        service.delegate?.netServiceDidResolveAddress(service)
        check(await until { discovery.discoveredDevices.count == 1 }, "not published")
        check(discovery.discoveredDevices.first?.host == "10.0.0.42")
        check(discovery.discoveredDevices.first?.name == "Living Room")
        check(seen.count == 1)
        browser.fakeResults([])
        check(await until { discovery.discoveredDevices.isEmpty }, "a TV that left must drop off")
        discovery.stopDiscovery()
        check(browser.fakeCancelled)
        check(!discovery.isSearching)
    }

    await test("disc.resolveFailureIsQuiet") {
        let discovery = BonjourDiscovery()
        discovery.startDiscovery()
        let browser = NWBrowser.fakeAll.last!
        NetService.fakeAll = []
        browser.fakeResults(["Bedroom"])
        check(await until { !NetService.fakeAll.isEmpty })
        let service = NetService.fakeAll[0]
        service.delegate?.netService(service, didNotResolve: [:])
        await settle()
        check(discovery.discoveredDevices.isEmpty)
        discovery.stopDiscovery()
    }

    await test("mgr.discovery.movedTVUpdatesRecord") {
        let m = makeManager([tvA])
        m.discovery.startDiscovery()
        let browser = NWBrowser.fakeAll.last!
        NetService.fakeAll = []
        browser.fakeResults([tvA.name])
        check(await until { !NetService.fakeAll.isEmpty })
        let service = NetService.fakeAll[0]
        service.port = 6466
        service.addresses = [sockaddrData(ip: "10.0.0.77", port: 6466)]
        service.delegate?.netServiceDidResolveAddress(service)
        check(await until { m.pairedDevices[0].host == "10.0.0.77" }, "\(m.pairedDevices[0].host)")
        check(m.pairedDevices[0].id == tvA.id)
        check((WCSession.default.applicationContext["pairedDevices"] as? [[String: Any]])?.first?["host"] as? String == "10.0.0.77", "the Watch must learn the new address")
        m.discovery.stopDiscovery()
    }
}
