import SwiftUI

/// Remote screens are always dark, for use in a dark room. Lists follow the system.
enum RemoteTheme {
    static let background = Color(rgb: 0x0A0B0D)
    static let disc = Color(rgb: 0x1C1F24)
    static let discPressed = Color(rgb: 0x2C3138)
    static let label = Color(rgb: 0xF2F4F7)
    static let secondary = Color(rgb: 0xA7AEB8)
    static let phosphor = Color(rgb: 0x6FD3FF)
    static let amber = Color(rgb: 0xFFB340)
    static let ember = Color(rgb: 0xFF6B5E)
    static let green = Color(rgb: 0x5EDC8A)

    /// Opacity applied to controls that can't be used right now.
    static let dimmedOpacity = 0.35

    static func track(_ contrast: ColorSchemeContrast) -> Color {
        Color.white.opacity(contrast == .increased ? 0.28 : 0.14)
    }

    static func secondaryText(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? label : secondary
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

enum RemoteMotion {
    static func press(isDown: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        return isDown
            ? .spring(response: 0.18, dampingFraction: 0.7)
            : .spring(response: 0.28, dampingFraction: 0.8)
    }

    static func slot(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85)
    }

    static func level(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .snappy
    }
}

/// The one haptic vocabulary of the remote. `sensoryFeedback` only plays when its
/// trigger changes, so repeats of the same haptic need the tick in `HapticPulse`.
enum RemoteHaptic: Equatable {
    case soft, medium, selection, rigid, heavy, success, warning, error

    var feedback: SensoryFeedback {
        switch self {
        case .soft: return .impact(flexibility: .soft, intensity: 0.6)
        case .medium: return .impact(weight: .medium, intensity: 0.8)
        case .selection: return .selection
        case .rigid: return .impact(flexibility: .rigid, intensity: 1)
        case .heavy: return .impact(weight: .heavy)
        case .success: return .success
        case .warning: return .warning
        case .error: return .error
        }
    }
}

struct HapticPulse: Equatable {
    private(set) var haptic = RemoteHaptic.soft
    private var tick = 0

    mutating func play(_ haptic: RemoteHaptic) {
        self.haptic = haptic
        tick &+= 1
    }
}

private struct ContrastStroke<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if contrast == .increased {
                shape.strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Increase Contrast draws an edge on disc-coloured surfaces.
    func contrastStroke<S: InsettableShape>(_ shape: S) -> some View {
        modifier(ContrastStroke(shape: shape))
    }
}
