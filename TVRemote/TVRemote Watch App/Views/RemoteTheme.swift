import CoreGraphics
import SwiftUI

/// Colors for the remote. Remote screens are always dark, the room usually is too.
enum RemoteTheme {
    static let background = Color.black
    static let disc = Color(rgb: 0x1C1F24)
    static let discPressed = Color(rgb: 0x2C3138)
    static let label = Color(rgb: 0xF2F4F7)
    static let secondary = Color(rgb: 0xA7AEB8)
    static let phosphor = Color(rgb: 0x6FD3FF)
    static let amber = Color(rgb: 0xFFB340)
    static let ember = Color(rgb: 0xFF6B5E)
    static let green = Color(rgb: 0x5EDC8A)

    /// Increase Contrast promotes captions to the primary label color.
    static func secondaryText(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? label : secondary
    }
}

extension Color {
    fileprivate init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Halo proportions, all from the outer diameter D, so nothing can drift between
/// watch sizes.
struct HaloMetrics {
    let diameter: CGFloat

    var ringRadius: CGFloat { diameter * 0.4725 }
    var ringStroke: CGFloat { diameter * 0.055 }
    var discDiameter: CGFloat { diameter * 0.84 }
    var okDiameter: CGFloat { diameter * 0.36 }
    var wedgeInnerRadius: CGFloat { diameter * 0.195 }
    var wedgeOuterRadius: CGFloat { diameter * 0.42 }
    var chevronRadius: CGFloat { diameter * 0.30 }
    var chevronSize: CGFloat { diameter * 0.09 }
    var capsuleHeight: CGFloat { diameter * 0.13 }
    var digitSize: CGFloat { diameter * 0.095 }
    var captionSize: CGFloat { diameter * 0.075 }
}
