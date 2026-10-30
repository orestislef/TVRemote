# protocol notes

What the apps actually send, for anyone changing this code. Field numbers come from `remotemessage.proto` in the [androidtvremote2](https://github.com/tronikos/androidtvremote2) project.

## finding the tv

Bonjour service `_androidtvremote2._tcp`. The address can change, so paired TVs are matched by name and their stored host gets updated when they show up on a new IP.

## pairing, port 6467

TLS with a self-signed RSA 2048 client certificate. The iPhone generates it once and keeps it in the keychain.

1. Pairing request, option and configuration messages go back and forth (fields 10, 20, 30).
2. The TV shows a 6 character hex code.
3. The app sends the secret (field 40), which proves it saw the code:

```
SHA256(clientModulus + clientExponent + serverModulus + serverExponent + code[1..])
```

The first byte of the code isn't hashed. It's a check byte.

## remote session, port 6466

TLS with the same client certificate. Every message is protobuf with a varint length in front. Frames over 1 MiB mean the stream lost sync, and that ends the session.

### handshake

1. TV sends `remote_configure`, app replies with its own, feature mask 615 (ping, key, IME, power, volume, app link).
2. TV sends `remote_set_active`, app replies with the same mask.

The session counts as up on `set_active`, or 2 seconds after `configure` if `set_active` never comes. These bytes must not change. The TV accepts them as they are, and the tests pin them against hand worked hex.

### top level fields

| field | message | direction | notes |
|---|---|---|---|
| 1 | remote_configure | both | feature mask, device info |
| 2 | remote_set_active | both | |
| 3 | remote_error | from tv | before the handshake it fails the connect, after it the session stays up |
| 8 | remote_ping_request | from tv | every 5 seconds or so |
| 9 | remote_ping_response | to tv | echoes the value |
| 10 | remote_key_inject | to tv | key_code = 1, direction = 2 |
| 20 | remote_ime_key_inject | from tv | app_info = 1, with label = 10 and package = 12 |
| 40 | remote_start | from tv | started = 1, false means standby |
| 50 | remote_set_volume_level | from tv | max = 6, level = 7, muted = 8 |

Directions are `START_LONG = 1`, `END_LONG = 2`, `SHORT = 3`. Holding a key repeats `SHORT`.

proto3 leaves out default values, so a volume message with no level means 0 and no mute means false. A max of 0 means an external device owns the volume, and the apps show `--` instead of a number.

### noticing a dead session

- TCP keepalive and `connectionDropTime = 10` catch a TV that vanished.
- 16 seconds with no traffic either way means the session is stale.
- 60 seconds with nothing received ends it too. This limit is long on purpose, since the TV may not ping while it is getting commands.

After a drop the app retries at 1, 2, 4, 8 and 8 seconds. The count resets once a session has stayed up for 30 seconds.

## watch and iphone

A real Apple Watch can't open a socket to the TV (see [TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)), so the iPhone holds the TV connection and relays over WatchConnectivity. The simulator has no such limit, so the Watch can connect directly there, and that is why the certificate gets synced.

### watch to iphone, with a reply

| action | fields | reply |
|---|---|---|
| getDevices | | `devices` |
| getState | | `state`, `phoneInUse` |
| connect | `deviceId` | `status: connected`, `state` |
| disconnect | | `status: disconnected` |
| command | `command`, `deviceId` | `status: ok`, `state` |

Any of them can answer `status: error` with a `failure` and an optional `message`. Replies always fire, once.

### iphone to watch, no reply

| action | fields | notes |
|---|---|---|
| tvState | `state`, `phoneInUse` | at most one every 100 ms, always the latest |
| commandRejected | | the TV sent `remote_error`, so the Watch plays a failure haptic |

`state` is `TVStatus.wirePayload`. `phoneInUse` is true while the iPhone app is in the foreground. When it is, the Watch follows what the phone does and doesn't take the TV back. If you press Disconnect on the phone, the Watch stays disconnected.

The TV list and certificate go through `applicationContext`, so they arrive even when the Watch isn't reachable at that moment.

The iPhone can't wake the Watch, but a Watch message wakes the iPhone app in the background for a short time. The app holds a background task for 25 seconds, refreshed on every message. After iOS suspends it, the first press takes a second or two to reconnect.
