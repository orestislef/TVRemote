<p align="center">
  <img src="ios/AppIcon@3x.png" width="96" alt="TVRemote icon">
</p>

<h1 align="center">TVRemote</h1>

<p align="center">Control your Android TV from your Apple Watch and iPhone. No server, no account, no dependencies.</p>

<!--
  screenshots go here once taken, for example:
  <p align="center"><img src="docs/screenshots/iphone.png" height="420"> <img src="docs/screenshots/watch.png" height="220"></p>
-->

It talks to the TV with the same protocol as Google's TV remote app (Android TV Remote Protocol v2), over your own Wi-Fi. All the TLS, certificate and protobuf code is written by hand in Swift, so there are no packages to install.

## what it does

### on the watch

- D-pad with a volume ring around it, same layout as the iPhone
- Digital Crown changes volume, one click is one key press
- shows the same things as the phone: volume, mute, current app, TV on or off
- haptics on every key, with a different one for connecting, failing and hitting the volume limit
- second page with play, pause, seek, mute and channels
- double tap gesture for OK or play, on watches that support it
- hold the power button to turn off, so you can't do it by accident
- works in Always-On, with VoiceOver and with Increase Contrast
- watch face complication to open it quickly

### on the iphone

- finds TVs on your network and pairs with the code shown on screen
- remote fits one screen from SE to Pro Max, with a separate layout in landscape
- volume ring, hold to repeat, press animations and haptics
- current app and TV state at the top
- respects Reduce Motion, Reduce Transparency, Increase Contrast and Dynamic Type
- works on the Watch's behalf, including when the app is in the background

### when things go wrong

Both apps say what actually happened and what to do about it:

| what happened | what you see |
|---|---|
| short drop | nothing for 600 ms, then reconnecting, with the last volume dimmed |
| TV is off or in standby | "TV is off", OK turns into a power button |
| TV unreachable | retries at 1, 2, 4, 8, 8 seconds, then "Try Again" |
| TV forgot the pairing | "Pair Again" straight from the iPhone remote |
| Wi-Fi lost | says so, and reconnects when it's back |
| Local Network permission off | a button to open Settings |
| TV got a new IP | finds it again by name |
| iPhone out of range | "Can't Reach iPhone" on the Watch, with "Try Again" |
| you disconnect on the phone | the Watch doesn't fight you and reconnect |

## how it works

```
 Apple Watch  <-- WatchConnectivity -->  iPhone  <-- TLS 6466 (remote) -->  Android TV
                                                 <-- TLS 6467 (pairing) -->
```

A real Apple Watch can't open a socket to a device on your network, Apple blocks it ([TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)). So the iPhone holds the TV connection and the Watch goes through it. Your iPhone has to be nearby, but the app doesn't have to be open because a press on the Watch wakes it.

The simulator doesn't have that limit, so there the Watch connects to the TV directly.

Details are in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## requirements

- Xcode 26
- iPhone on iOS 26 or later
- Apple Watch on watchOS 11 or later (optional)
- Android TV or Google TV, on the same Wi-Fi as the iPhone

## setup

1. Clone the repo and open `TVRemote/TVRemote.xcodeproj`
2. Set your team under Signing & Capabilities for the three targets
3. Run the `TVRemote` scheme on your iPhone. The Watch app comes with it

## using it

1. Open the Discover tab and pick your TV
2. Type the code the TV shows
3. Tap the TV under My TVs and use the remote
4. Open TVRemote on your Watch, your TVs are already synced

## known limits

- The iPhone needs to be in range of the Watch.
- iOS suspends the iPhone app shortly after it goes to the background. After that the first press on the Watch takes a second or two while it reconnects.
- Turning the TV on from standby only works if the TV keeps its network on in standby, and that depends on the model.
- Volume shows `--` when an external device like a soundbar owns it. The keys still work.

## project layout

```
TVRemote/
  TVRemote/                 iPhone app
    Models/                 TVDevice, RemoteCommand, TVStatus
    Services/               connection, pairing, discovery, relay to the Watch
    Views/                  lists and pairing
    Views/Remote/           remote screen pieces
  TVRemote Watch App/       Watch app
    Models/, Services/      same idea, with the session manager on the iPhone relay
    Views/                  remote, crown volume, media page
  TVRemote Watch Widget/    complication
  Tests/                    service tests, run without Xcode
docs/PROTOCOL.md            what goes over the wire
```

`TVStatus.swift`, `RemoteProtocol.swift` and `ProtobufCoder.swift` exist in both targets and have to stay identical.

## tests

The connection, relay and pairing code has about 180 tests that run on Linux or WSL with fake Apple frameworks. See [Tests/README.md](TVRemote/Tests/README.md). The views aren't covered, those need Xcode.

## license

[MIT](LICENSE)
