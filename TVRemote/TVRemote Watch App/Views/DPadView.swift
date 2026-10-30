import CoreGraphics
import Foundation
import SwiftUI

enum PadMode {
    case live
    case dimmed
    /// Dimmed too, except that OK becomes a Power key.
    case tvOff
}

/// The disc: four wedges around a center key.
struct DPadView: View {
    let metrics: HaloMetrics
    let mode: PadMode
    let isDoubleTapEnabled: Bool
    let press: KeyPress

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            ZStack {
                discBackground
                ForEach(PadDirection.allCases, id: \.self) { direction in
                    wedge(direction)
                }
                PadSeparators(
                    innerRadius: metrics.wedgeInnerRadius,
                    outerRadius: metrics.wedgeOuterRadius
                )
                .stroke(
                    isLuminanceReduced ? RemoteTheme.secondary : RemoteTheme.background,
                    lineWidth: isLuminanceReduced ? 1 : 2
                )
                .allowsHitTesting(false)
            }
            .opacity(mode == .live ? 1 : 0.35)
            .disabled(mode != .live)

            centerKey
        }
        .frame(width: metrics.discDiameter, height: metrics.discDiameter)
    }

    @ViewBuilder
    private var discBackground: some View {
        if isLuminanceReduced {
            Circle().stroke(RemoteTheme.secondary, lineWidth: 1)
        } else {
            Circle().fill(RemoteTheme.disc)
            if contrast == .increased {
                Circle().stroke(Color.white.opacity(0.4), lineWidth: 1)
            }
        }
    }

    private func wedge(_ direction: PadDirection) -> some View {
        let radius = metrics.discDiameter / 2
        let size = direction.frameSize(radius: radius)
        let anchor = direction.anchor
        let shape = PadWedge(
            centerDegrees: direction.degrees,
            anchor: anchor,
            innerRadius: metrics.wedgeInnerRadius,
            outerRadius: metrics.wedgeOuterRadius
        )
        let chevron = CGPoint(
            x: size.width * anchor.x + direction.unit.x * metrics.chevronRadius,
            y: size.height * anchor.y + direction.unit.y * metrics.chevronRadius
        )

        return RemoteKey(title: direction.title, command: direction.command, repeats: true, press: press) { isPressed in
            ZStack {
                shape.fill(isPressed ? RemoteTheme.discPressed : Color.clear)
                Image(systemName: direction.symbol)
                    .font(.system(size: metrics.chevronSize, weight: .bold))
                    .foregroundStyle(isLuminanceReduced ? RemoteTheme.secondary : RemoteTheme.label)
                    .position(chevron)
            }
            .contentShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: direction.alignment)
    }

    @ViewBuilder
    private var centerKey: some View {
        if mode == .tvOff {
            RemoteKey(title: "Turn TV On", command: .power, haptic: .start, press: press) { isPressed in
                KeyFace(shape: Circle(), tint: RemoteTheme.ember, isPressed: isPressed) {
                    Image(systemName: "power")
                        .font(.system(size: metrics.okDiameter * 0.42, weight: .bold))
                }
            }
            .frame(width: metrics.okDiameter, height: metrics.okDiameter)
            .handGestureShortcut(.primaryAction, isEnabled: isDoubleTapEnabled)
        } else {
            RemoteKey(title: "Select", command: .ok, press: press) { isPressed in
                KeyFace(shape: Circle(), tint: RemoteTheme.phosphor, isPressed: isPressed) {
                    Text("OK")
                        .font(.system(size: metrics.okDiameter * 0.3, weight: .bold, design: .rounded))
                }
            }
            .frame(width: metrics.okDiameter, height: metrics.okDiameter)
            .handGestureShortcut(.primaryAction, isEnabled: isDoubleTapEnabled && mode == .live)
            .opacity(mode == .live ? 1 : 0.35)
            .disabled(mode != .live)
        }
    }
}

private enum PadDirection: CaseIterable {
    case up, right, down, left

    var title: String {
        switch self {
        case .up: return "Up"
        case .right: return "Right"
        case .down: return "Down"
        case .left: return "Left"
        }
    }

    var command: RemoteCommand {
        switch self {
        case .up: return .up
        case .right: return .right
        case .down: return .down
        case .left: return .left
        }
    }

    var symbol: String {
        switch self {
        case .up: return "chevron.up"
        case .right: return "chevron.right"
        case .down: return "chevron.down"
        case .left: return "chevron.left"
        }
    }

    /// 0 is 3 o'clock, and angles grow clockwise on screen.
    var degrees: Double {
        switch self {
        case .up: return 270
        case .right: return 0
        case .down: return 90
        case .left: return 180
        }
    }

    var unit: CGPoint {
        switch self {
        case .up: return CGPoint(x: 0, y: -1)
        case .right: return CGPoint(x: 1, y: 0)
        case .down: return CGPoint(x: 0, y: 1)
        case .left: return CGPoint(x: -1, y: 0)
        }
    }

    /// Where the disc's center sits inside this wedge's half-disc frame.
    var anchor: UnitPoint {
        switch self {
        case .up: return .bottom
        case .right: return .leading
        case .down: return .top
        case .left: return .trailing
        }
    }

    var alignment: Alignment {
        switch self {
        case .up: return .top
        case .right: return .trailing
        case .down: return .bottom
        case .left: return .leading
        }
    }

    /// Each wedge gets half the disc as its frame, so VoiceOver focus lands on
    /// the right side rather than on the whole disc.
    func frameSize(radius: CGFloat) -> CGSize {
        switch self {
        case .up, .down: return CGSize(width: radius * 2, height: radius)
        case .left, .right: return CGSize(width: radius, height: radius * 2)
        }
    }
}

// Shape requires a nonisolated path(in:), which the module's default MainActor
// isolation would otherwise break.
private nonisolated struct PadWedge: Shape {
    let centerDegrees: Double
    let anchor: UnitPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(
            x: rect.minX + rect.width * anchor.x,
            y: rect.minY + rect.height * anchor.y
        )
        var path = Path()
        path.addRelativeArc(
            center: center,
            radius: outerRadius,
            startAngle: .degrees(centerDegrees - 45),
            delta: .degrees(90)
        )
        path.addRelativeArc(
            center: center,
            radius: innerRadius,
            startAngle: .degrees(centerDegrees + 45),
            delta: .degrees(-90)
        )
        path.closeSubpath()
        return path
    }
}

private nonisolated struct PadSeparators: Shape {
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for degrees in stride(from: 45.0, to: 360.0, by: 90.0) {
            let radians = degrees * .pi / 180
            let dx = CGFloat(cos(radians))
            let dy = CGFloat(sin(radians))
            path.move(to: CGPoint(x: rect.midX + dx * innerRadius, y: rect.midY + dy * innerRadius))
            path.addLine(to: CGPoint(x: rect.midX + dx * outerRadius, y: rect.midY + dy * outerRadius))
        }
        return path
    }
}
