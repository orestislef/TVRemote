# tests

These cover the connection, relay and pairing code in both apps. They run the real files from `Models/` and `Services/`, built against fake versions of Network, WatchConnectivity, Security, CryptoKit, UIKit and os. So you can run them with no Mac, no Watch and no TV.

They are not part of the Xcode project and nothing in here ships.

## running

You need Swift 6.2 on Linux or WSL. The fakes take the place of Apple's modules, which only works where those modules don't exist, so this has not been tried on a Mac.

```
Tests/run.sh                  # both apps
Tests/run.sh watch            # one app
Tests/run.sh phone relay.     # only tests whose name starts with relay.
SWIFTC=~/swift/usr/bin/swiftc Tests/run.sh
```

The tests use real time, with short real waits for retries and timeouts, so a full run takes a few minutes. Build output goes to `~/.cache/tvremote-tests`.

## what is in here

- `Suites/` has the tests and a small test runner. `ConnTests.swift` runs against both connection classes.
- `Stubs/` has the fake frameworks. The fake `NWConnection` lets a test feed bytes in and read what the app sent, and goes `.waiting(ENETDOWN)` the way a real Watch does.

## what they don't cover

- SwiftUI views. Those need Xcode.
- Real TLS and the real keychain. `CertificateManager` and `WatchCertificateStore` are replaced by fakes here.
- How iOS really suspends the app, and how a real TV behaves.
