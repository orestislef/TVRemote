import Foundation

// Keep this file identical in the iPhone and Watch targets. Field numbers come
// from remotemessage.proto in the androidtvremote2 project.

/// Feature bitmask matching the reference client (no voice/mic):
/// PING|KEY|IME|POWER|VOLUME|APP_LINK = 1|2|4|32|64|512
let remoteDefaultFeatureMask: UInt64 = 615

enum RemoteEvent: Equatable, Sendable {
    case configure(features: UInt64)
    case setActive
    case ping(UInt64)
    /// remote_start: the TV is awake (true) or in standby (false).
    case tvPower(Bool)
    /// proto3 omits defaults, so a missing level means 0 and missing mute means false.
    case volume(level: Int, max: Int?, muted: Bool)
    case app(label: String, package: String)
    case error(UInt64)
}

/// Direction values for remote_key_inject.
enum KeyDirection: UInt64, Sendable {
    case startLong = 1
    case endLong = 2
    case short = 3
}

enum RemoteProtocol {

    // MARK: - Decoding

    static func decode(_ payload: Data) -> [RemoteEvent] {
        var events: [RemoteEvent] = []
        var decoder = ProtobufDecoder(data: payload)
        while let tag = decoder.readTag() {
            switch (tag.field, tag.wireType) {
            case (1, 2):
                let code = firstVarint(in: decoder.readLengthDelimited())
                events.append(.configure(features: code))
            case (2, 2):
                _ = decoder.readLengthDelimited()
                events.append(.setActive)
            case (3, 2):
                let code = firstVarint(in: decoder.readLengthDelimited())
                events.append(.error(code))
            case (8, 2):
                let value = firstVarint(in: decoder.readLengthDelimited())
                events.append(.ping(value))
            case (20, 2):
                if let event = decodeApp(decoder.readLengthDelimited()) {
                    events.append(event)
                }
            case (40, 2):
                events.append(.tvPower(firstVarint(in: decoder.readLengthDelimited()) != 0))
            case (50, 2):
                events.append(decodeVolume(decoder.readLengthDelimited()))
            default:
                decoder.skip(wireType: tag.wireType)
            }
        }
        return events
    }

    private static func firstVarint(in body: Data) -> UInt64 {
        var decoder = ProtobufDecoder(data: body)
        while let tag = decoder.readTag() {
            if tag.field == 1 && tag.wireType == 0 { return decoder.readVarint() }
            decoder.skip(wireType: tag.wireType)
        }
        return 0
    }

    private static func decodeVolume(_ body: Data) -> RemoteEvent {
        var decoder = ProtobufDecoder(data: body)
        var level = 0
        var max: Int?
        var muted = false
        while let tag = decoder.readTag() {
            switch (tag.field, tag.wireType) {
            case (6, 0):
                let value = Int(truncatingIfNeeded: decoder.readVarint())
                max = value > 0 ? value : nil
            case (7, 0):
                level = Swift.max(0, Int(truncatingIfNeeded: decoder.readVarint()))
            case (8, 0):
                muted = decoder.readVarint() != 0
            default:
                decoder.skip(wireType: tag.wireType)
            }
        }
        return .volume(level: level, max: max, muted: muted)
    }

    private static func decodeApp(_ body: Data) -> RemoteEvent? {
        var decoder = ProtobufDecoder(data: body)
        while let tag = decoder.readTag() {
            guard tag.field == 1 && tag.wireType == 2 else {
                decoder.skip(wireType: tag.wireType)
                continue
            }
            var app = ProtobufDecoder(data: decoder.readLengthDelimited())
            var label = ""
            var package = ""
            while let appTag = app.readTag() {
                if appTag.field == 10 && appTag.wireType == 2 {
                    label = app.readString()
                } else if appTag.field == 12 && appTag.wireType == 2 {
                    package = app.readString()
                } else {
                    app.skip(wireType: appTag.wireType)
                }
            }
            return label.isEmpty && package.isEmpty ? nil : .app(label: label, package: package)
        }
        return nil
    }

    // MARK: - Building (bytes must stay as they are, the TV accepts them)

    static func configureReply(features: UInt64) -> Data {
        var deviceInfo = ProtobufEncoder()
        deviceInfo.addVarint(field: 3, value: 1)           // unknown1
        deviceInfo.addString(field: 4, value: "1")         // unknown2
        deviceInfo.addString(field: 5, value: "atvremote") // package_name
        deviceInfo.addString(field: 6, value: "1.0.0")     // app_version

        var configure = ProtobufEncoder()
        configure.addVarint(field: 1, value: features)     // code1 (feature bitmask)
        configure.addMessage(field: 2, encoder: deviceInfo)

        var message = ProtobufEncoder()
        message.addMessage(field: 1, encoder: configure)   // remote_configure = field 1

        return MessageFraming.frame(message.encoded)
    }

    static func setActiveReply(features: UInt64) -> Data {
        var setActive = ProtobufEncoder()
        setActive.addVarint(field: 1, value: features)     // active = feature bitmask

        var message = ProtobufEncoder()
        message.addMessage(field: 2, encoder: setActive)   // remote_set_active = field 2

        return MessageFraming.frame(message.encoded)
    }

    static func keyInject(keyCode: Int32, direction: KeyDirection = .short) -> Data {
        var keyInject = ProtobufEncoder()
        keyInject.addVarint(field: 1, value: UInt64(keyCode))         // key_code
        keyInject.addVarint(field: 2, value: direction.rawValue)      // direction

        var message = ProtobufEncoder()
        message.addMessage(field: 10, encoder: keyInject)  // remote_key_inject = field 10

        return MessageFraming.frame(message.encoded)
    }

    static func pingResponse(value: UInt64) -> Data {
        var ping = ProtobufEncoder()
        ping.addVarint(field: 1, value: value)

        var message = ProtobufEncoder()
        message.addMessage(field: 9, encoder: ping)        // remote_ping_response = field 9

        return MessageFraming.frame(message.encoded)
    }
}
