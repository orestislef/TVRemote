import Foundation

// MARK: - Protobuf Encoder

struct ProtobufEncoder {
    private var data = Data()

    static func varint(_ value: UInt64) -> Data {
        var result = Data()
        var v = value
        while v > 127 {
            result.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        result.append(UInt8(v))
        return result
    }

    mutating func addVarint(field: Int, value: UInt64) {
        let tag = UInt64(field << 3) | 0
        data.append(contentsOf: Self.varint(tag))
        data.append(contentsOf: Self.varint(value))
    }

    mutating func addBool(field: Int, value: Bool) {
        addVarint(field: field, value: UInt64(value ? 1 : 0))
    }

    mutating func addLengthDelimited(field: Int, value: Data) {
        let tag = UInt64(field << 3) | 2
        data.append(contentsOf: Self.varint(tag))
        data.append(contentsOf: Self.varint(UInt64(value.count)))
        data.append(value)
    }

    mutating func addString(field: Int, value: String) {
        addLengthDelimited(field: field, value: Data(value.utf8))
    }

    mutating func addBytes(field: Int, value: Data) {
        addLengthDelimited(field: field, value: value)
    }

    mutating func addMessage(field: Int, encoder: ProtobufEncoder) {
        addLengthDelimited(field: field, value: encoder.data)
    }

    var encoded: Data { data }
}

// MARK: - Protobuf Decoder

struct ProtobufDecoder {
    let data: Data
    var offset: Int = 0

    var hasMore: Bool { offset < data.count }

    mutating func readVarint() -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[data.startIndex + offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }

    mutating func readTag() -> (field: Int, wireType: Int)? {
        guard hasMore else { return nil }
        let tag = readVarint()
        return (field: Int(tag >> 3), wireType: Int(tag & 7))
    }

    mutating func readLengthDelimited() -> Data {
        let length = Int(clamping: readVarint())
        guard length <= data.count - offset else {
            offset = data.count
            return Data()
        }
        let start = data.startIndex + offset
        let result = data[start..<start + length]
        offset += length
        return Data(result)
    }

    mutating func readString() -> String {
        let bytes = readLengthDelimited()
        return String(data: bytes, encoding: .utf8) ?? ""
    }

    mutating func skip(wireType: Int) {
        switch wireType {
        case 0: _ = readVarint()
        case 1: advance(by: 8)
        case 2: advance(by: Int(clamping: readVarint()))
        case 5: advance(by: 4)
        default: break
        }
    }

    private mutating func advance(by count: Int) {
        offset = count <= data.count - offset ? offset + count : data.count
    }
}

// MARK: - Message Framing (varint length prefix)

enum MessageFraming {
    static func frame(_ message: Data) -> Data {
        var framed = Data()
        framed.append(contentsOf: ProtobufEncoder.varint(UInt64(message.count)))
        framed.append(message)
        return framed
    }

    /// Largest frame we accept. Real TV messages are far smaller, so anything
    /// bigger means the stream lost sync.
    static let maxFrameLength: UInt64 = 1 << 20

    enum Frame {
        case message(Data)
        case incomplete
        /// The stream lost sync. The buffer has been cleared, and what follows on
        /// the socket starts at a random offset, so the session can't be trusted.
        case corrupt
    }

    static func extractMessage(from buffer: inout Data) -> Data? {
        if case .message(let message) = nextFrame(from: &buffer) { return message }
        return nil
    }

    static func nextFrame(from buffer: inout Data) -> Frame {
        // The length prefix may arrive split across TCP reads, so read it by
        // hand and wait for the rest instead of trusting a partial varint.
        var length: UInt64 = 0
        var shift: UInt64 = 0
        var headerSize = 0
        var headerComplete = false
        for byte in buffer {
            headerSize += 1
            length |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                headerComplete = true
                break
            }
            shift += 7
            if shift >= 64 {
                buffer.removeAll()
                return .corrupt
            }
        }
        guard headerComplete else { return .incomplete }
        guard length <= maxFrameLength else {
            buffer.removeAll()
            return .corrupt
        }
        let frameLength = Int(length)
        guard buffer.count >= headerSize + frameLength else { return .incomplete }
        let start = buffer.startIndex + headerSize
        let message = Data(buffer[start..<start + frameLength])
        buffer.removeFirst(headerSize + frameLength)
        return .message(message)
    }
}
