# TVRemote

An Apple Watch + iPhone app to control Android TVs using the Android TV Remote Protocol v2.

## Features

### Apple Watch App
- **Direct connection** to Android TV over TLS (no iPhone needed after initial pairing)
- **D-Pad remote**: Up, Down, Left, Right, OK, Back, Power
- **Media controls**: Volume Up/Down, Mute, Channel Up/Down, Power
- **Watch face complication**: Quick-launch widget for your watch face (circular, rectangular, inline, corner styles)
- Falls back to iPhone proxy if direct connection fails

### iPhone Companion App
- **Bonjour discovery** of Android TVs on local network (`_androidtvremote2._tcp`)
- **TLS pairing** with PIN code entry (hex code shown on TV)
- **Paired TV management**: Save, remove, connect/disconnect
- **Certificate transfer** to Apple Watch via WatchConnectivity
- **Watch status**: Check if Watch app is installed
- **Animated splash screen**

## Architecture

```
┌─────────────┐     TLS (port 6466)     ┌──────────┐
│ Apple Watch  │◄───────────────────────►│          │
│  (Direct)    │                         │ Android  │
└─────────────┘                         │   TV     │
                                        │          │
┌─────────────┐     TLS (port 6466)     │          │
│   iPhone     │◄───────────────────────►│          │
│  (Pairing    │     TLS (port 6467)     │          │
│   + Proxy)   │◄───────────────────────►│          │
└─────────────┘                         └──────────┘
       ▲
       │ WatchConnectivity
       │ (cert transfer + device sync)
       ▼
┌─────────────┐
│ Apple Watch  │
│  (Fallback)  │
└─────────────┘
```

### How It Works

1. **Discovery**: iPhone uses Bonjour/mDNS to find Android TVs on the local network
2. **Pairing**: iPhone connects to TV's pairing port (6467) via TLS, exchanges a PIN code, computes `SHA256(clientCert + serverCert + codeBytes)` as the pairing secret
3. **Certificate Transfer**: After successful pairing, iPhone sends the TLS private key + certificate to the Watch via WatchConnectivity
4. **Direct Control**: Watch stores the certificate in its own Keychain and connects directly to the TV over TLS (port 6466)
5. **Protocol**: Commands are sent as protobuf-encoded messages (hand-coded encoder/decoder, no external dependencies)

## Protocol Details

- **Service**: `_androidtvremote2._tcp`
- **Pairing port**: 6467
- **Remote port**: 6466
- **TLS**: Self-signed RSA 2048 X.509 certificate (DER/ASN.1 built from scratch)
- **Messages**: Protobuf with varint length-prefix framing
- **Key messages**: RemoteConfigure, RemoteSetActive, RemoteKeyInject, Ping/Pong

## Requirements

- iOS 18.0+ / watchOS 11.0+
- Xcode 16+
- Apple Watch Series 4+
- Android TV with Remote Control v2 support

## Project Structure

```
TVRemote/
├── TVRemote/                    # iPhone app
│   ├── TVRemoteApp.swift
│   ├── ContentView.swift
│   ├── Models/
│   │   ├── TVDevice.swift
│   │   └── RemoteCommand.swift
│   ├── Services/
│   │   ├── BonjourDiscovery.swift
│   │   ├── CertificateManager.swift
│   │   ├── AndroidTVPairing.swift
│   │   ├── AndroidTVConnection.swift
│   │   ├── TVManager.swift
│   │   ├── PhoneSessionManager.swift
│   │   └── ProtobufCoder.swift
│   └── Views/
│       ├── DiscoveryView.swift
│       ├── PairingView.swift
│       ├── PairedTVsView.swift
│       ├── WatchStatusView.swift
│       └── SplashView.swift
├── TVRemote Watch App/          # Watch app
│   ├── TVRemoteApp.swift
│   ├── ContentView.swift
│   ├── Models/
│   │   ├── TVDevice.swift
│   │   └── RemoteCommand.swift
│   ├── Services/
│   │   ├── WatchSessionManager.swift
│   │   ├── WatchCertificateStore.swift
│   │   ├── WatchTVConnection.swift
│   │   └── ProtobufCoder.swift
│   └── Views/
│       ├── RemoteView.swift
│       ├── DPadView.swift
│       └── MediaControlView.swift
├── TVRemote Watch Widget/       # Watch complication
│   └── TVRemoteWidget.swift
├── Info.plist                   # iOS Bonjour permissions
└── WidgetInfo.plist             # Widget extension info
```

## Setup

1. Clone the repo
2. Open `TVRemote.xcodeproj` in Xcode
3. Set your development team in Signing & Capabilities
4. Build and run on your iPhone
5. The Watch app installs automatically when paired

## Usage

1. Open the iPhone app
2. Go to "Discover" tab - your Android TV should appear
3. Tap the TV to start pairing
4. Enter the hex code shown on your TV screen
5. The TV is now paired and the certificate is sent to your Watch
6. Open the Watch app - your TV appears in the list
7. Tap to connect and use the remote!

## License

MIT
