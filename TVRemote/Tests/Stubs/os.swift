// Mirrors the os.Logger surface. Signatures follow developer.apple.com/documentation/os/osloginterpolation.
import Foundation

public struct OSLogPrivacy: Sendable {
    public static var auto: OSLogPrivacy { OSLogPrivacy() }
    public static var `public`: OSLogPrivacy { OSLogPrivacy() }
    public static var `private`: OSLogPrivacy { OSLogPrivacy() }
    public static var sensitive: OSLogPrivacy { OSLogPrivacy() }
}
public struct OSLogStringAlignment: Sendable {
    public static var none: OSLogStringAlignment { OSLogStringAlignment() }
}
public struct OSLogIntegerFormatting: Sendable {
    public static var decimal: OSLogIntegerFormatting { OSLogIntegerFormatting() }
}
public struct OSLogFloatFormatting: Sendable {
    public static var fixed: OSLogFloatFormatting { OSLogFloatFormatting() }
}
public struct OSLogBoolFormat: Sendable {
    public static var truth: OSLogBoolFormat { OSLogBoolFormat() }
}

public struct OSLogInterpolation: StringInterpolationProtocol {
    var text = ""
    public init(literalCapacity: Int, interpolationCount: Int) {}
    public mutating func appendLiteral(_ literal: String) { text += literal }

    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> String, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += v() }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> Int, format: OSLogIntegerFormatting = .decimal, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> Int8, format: OSLogIntegerFormatting = .decimal, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> Int16, format: OSLogIntegerFormatting = .decimal, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> Int32, format: OSLogIntegerFormatting = .decimal, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> Int64, format: OSLogIntegerFormatting = .decimal, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> UInt, format: OSLogIntegerFormatting = .decimal, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> UInt8, format: OSLogIntegerFormatting = .decimal, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> UInt16, format: OSLogIntegerFormatting = .decimal, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> UInt32, format: OSLogIntegerFormatting = .decimal, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> UInt64, format: OSLogIntegerFormatting = .decimal, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> Double, format: OSLogFloatFormatting = .fixed, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> Float, format: OSLogFloatFormatting = .fixed, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> Bool, format: OSLogBoolFormat = .truth, privacy: OSLogPrivacy = .auto) { text += String(v()) }
    public mutating func appendInterpolation<T: CustomStringConvertible>(_ v: @autoclosure @escaping () -> T, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += v().description }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> any Any.Type, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(describing: v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> NSObject, privacy: OSLogPrivacy = .auto) { text += v().description }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> any Error, privacy: OSLogPrivacy = .auto, attributes: String = "") { text += String(describing: v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> (any Error)?, privacy: OSLogPrivacy = .auto, attributes: String = "") { text += String(describing: v()) }
    public mutating func appendInterpolation(_ v: @autoclosure @escaping () -> NSObject?, privacy: OSLogPrivacy = .auto, attributes: String = "") { text += String(describing: v()) }
}

public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    var text: String
    public init(stringInterpolation: OSLogInterpolation) { text = stringInterpolation.text }
    public init(stringLiteral value: String) { text = value }
}

public struct OSLogType: Sendable, Equatable {
    let raw: UInt8
    public static let `default` = OSLogType(raw: 0)
    public static let info = OSLogType(raw: 1)
    public static let debug = OSLogType(raw: 2)
    public static let error = OSLogType(raw: 16)
    public static let fault = OSLogType(raw: 17)
}

nonisolated(unsafe) private let verbose = ProcessInfo.processInfo.environment["STUB_LOG"] != nil

public struct Logger: Sendable {
    let category: String
    public init() { category = "" }
    public init(subsystem: String, category: String) { self.category = category }
    private func emit(_ level: String, _ m: OSLogMessage) { if verbose { print("[\(category)] \(level) \(m.text)") } }
    public func log(_ message: OSLogMessage) { emit("log", message) }
    public func log(level: OSLogType, _ message: OSLogMessage) { emit("log", message) }
    public func trace(_ message: OSLogMessage) { emit("trace", message) }
    public func debug(_ message: OSLogMessage) { emit("debug", message) }
    public func info(_ message: OSLogMessage) { emit("info", message) }
    public func notice(_ message: OSLogMessage) { emit("notice", message) }
    public func warning(_ message: OSLogMessage) { emit("warning", message) }
    public func error(_ message: OSLogMessage) { emit("error", message) }
    public func critical(_ message: OSLogMessage) { emit("critical", message) }
    public func fault(_ message: OSLogMessage) { emit("fault", message) }
}
