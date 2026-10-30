import Foundation
import SwiftUI

// Geometry as fractions of the outer diameter D, so the Halo scales as one piece.
nonisolated private enum HaloMetrics {
    static let ringRadius: CGFloat = 0.4725
    static let ringStroke: CGFloat = 0.055
    static let gapDegrees: Double = 80
    static let discDiameter: CGFloat = 0.84
    static let okDiameter: CGFloat = 0.36
    static let wedgeInner: CGFloat = 0.195
    static let wedgeOuter: CGFloat = 0.42
    static let chevronRadius: CGFloat = 0.30
    static let chevronSize: CGFloat = 0.09
    static let capsuleHeight: CGFloat = 0.13
    static let digitSize: CGFloat = 0.095
    static let reservedHeight: CGFloat = 1.04
}

/// The gauge, swept clockwise from the end of the 6 o'clock gap.
nonisolated private struct HaloArc: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // A zero-length arc would still draw a round cap and read as volume.
        guard fraction > 0 else { return path }
        let sweep = 360 - HaloMetrics.gapDegrees
        path.addRelativeArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) * HaloMetrics.ringRadius,
            startAngle: .degrees(90 + HaloMetrics.gapDegrees / 2),
            delta: .degrees(sweep * min(fraction, 1))
        )
        return path
    }
}

/// One 90 degree annular sector of the D-pad, in the Halo's full D by D square.
nonisolated private struct WedgeShape: Shape {
    let centerDegrees: Double

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addRelativeArc(
            center: center,
            radius: side * HaloMetrics.wedgeOuter,
            startAngle: .degrees(centerDegrees - 45),
            delta: .degrees(90)
        )
        path.addRelativeArc(
            center: center,
            radius: side * HaloMetrics.wedgeInner,
            startAngle: .degrees(centerDegrees + 45),
            delta: .degrees(-90)
        )
        path.closeSubpath()
        return path
    }
}

nonisolated private struct WedgeSeparators: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        var path = Path()
        for degrees in [45.0, 135.0, 225.0, 315.0] {
            let radians = degrees * .pi / 180
            let dx = CGFloat(cos(radians))
            let dy = CGFloat(sin(radians))
            path.move(to: CGPoint(
                x: rect.midX + dx * side * HaloMetrics.wedgeInner,
                y: rect.midY + dy * side * HaloMetrics.wedgeInner
            ))
            path.addLine(to: CGPoint(
                x: rect.midX + dx * side * HaloMetrics.wedgeOuter,
                y: rect.midY + dy * side * HaloMetrics.wedgeOuter
            ))
        }
        return path
    }
}

private enum PadDirection: CaseIterable {
    case up, left, right, down

    var title: String {
        switch self {
        case .up: return "Up"
        case .left: return "Left"
        case .right: return "Right"
        case .down: return "Down"
        }
    }

    var command: RemoteCommand {
        switch self {
        case .up: return .up
        case .left: return .left
        case .right: return .right
        case .down: return .down
        }
    }

    var symbol: String {
        switch self {
        case .up: return "chevron.up"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        case .down: return "chevron.down"
        }
    }

    /// Screen angle: 0 points right and values grow clockwise.
    var degrees: Double {
        switch self {
        case .up: return 270
        case .left: return 180
        case .right: return 0
        case .down: return 90
        }
    }

    var unit: CGSize {
        switch self {
        case .up: return CGSize(width: 0, height: -1)
        case .left: return CGSize(width: -1, height: 0)
        case .right: return CGSize(width: 1, height: 0)
        case .down: return CGSize(width: 0, height: 1)
        }
    }
}

/// A volume gauge with the D-pad inside it. `discOverlay` replaces the wedges and
/// OK with whatever the disc should say instead, when `showsDiscOverlay` is true.
struct HaloPad<DiscOverlay: View>: View {
    private let diameter: CGFloat
    private let status: TVStatus
    private let isReconnecting: Bool
    private let isLive: Bool
    private let isTVOff: Bool
    private let showsDiscOverlay: Bool
    private let send: (RemoteCommand, _ isRepeat: Bool) -> Void
    private let discOverlay: DiscOverlay

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var pressedDirection: PadDirection?

    init(
        diameter: CGFloat,
        status: TVStatus,
        isReconnecting: Bool,
        isLive: Bool,
        isTVOff: Bool,
        showsDiscOverlay: Bool,
        send: @escaping (RemoteCommand, _ isRepeat: Bool) -> Void,
        @ViewBuilder discOverlay: () -> DiscOverlay
    ) {
        self.diameter = diameter
        self.status = status
        self.isReconnecting = isReconnecting
        self.isLive = isLive
        self.isTVOff = isTVOff
        self.showsDiscOverlay = showsDiscOverlay
        self.send = send
        self.discOverlay = discOverlay()
    }

    var body: some View {
        ZStack(alignment: .top) {
            ring
            pad
            if !showsDiscOverlay {
                HaloReadout(
                    diameter: diameter,
                    status: status,
                    isDimmed: isReconnecting,
                    isLive: isLive,
                    send: send
                )
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(height: diameter * HaloMetrics.capsuleHeight)
                // Centred on the ring's centerline at 6 o'clock.
                .offset(y: diameter * (0.5 + HaloMetrics.ringRadius - HaloMetrics.capsuleHeight / 2))
                .accessibilitySortPriority(1)
            }
        }
        .frame(width: diameter, height: diameter * HaloMetrics.reservedHeight)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Ring

    private var ring: some View {
        let style = StrokeStyle(lineWidth: diameter * HaloMetrics.ringStroke, lineCap: .round)
        return ZStack {
            HaloArc(fraction: 1)
                .stroke(RemoteTheme.track(contrast), style: style)
            if let fraction = status.volumeFraction {
                HaloArc(fraction: fraction)
                    .stroke(status.isMuted ? RemoteTheme.amber.opacity(0.35) : RemoteTheme.phosphor, style: style)
                    .opacity(isReconnecting ? 0.5 : 1)
                    .animation(RemoteMotion.level(reduceMotion: reduceMotion), value: fraction)
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Disc, wedges, OK

    private var discOpacity: Double {
        if showsDiscOverlay { return 0.15 }
        return isLive ? 1 : RemoteTheme.dimmedOpacity
    }

    private var pad: some View {
        ZStack {
            ZStack {
                Circle()
                    .fill(RemoteTheme.disc)
                    .frame(
                        width: diameter * HaloMetrics.discDiameter,
                        height: diameter * HaloMetrics.discDiameter
                    )
                    .contrastStroke(Circle())

                if !showsDiscOverlay {
                    ForEach(PadDirection.allCases, id: \.self) { direction in
                        wedge(direction)
                    }
                    WedgeSeparators()
                        .stroke(RemoteTheme.background, lineWidth: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .compositingGroup()
            .opacity(discOpacity)
            .disabled(!isLive)

            if showsDiscOverlay {
                discOverlay
                    .frame(width: diameter * HaloMetrics.discDiameter * 0.82)
            } else {
                okButton
            }
        }
        .frame(width: diameter, height: diameter)
        .rotation3DEffect(.degrees(tilt.x), axis: (x: 1, y: 0, z: 0))
        .rotation3DEffect(.degrees(tilt.y), axis: (x: 0, y: 1, z: 0))
        .animation(
            RemoteMotion.press(isDown: pressedDirection != nil, reduceMotion: reduceMotion),
            value: pressedDirection
        )
    }

    /// The disc leans 3 degrees toward the pressed wedge.
    private var tilt: (x: Double, y: Double) {
        guard !reduceMotion, let pressedDirection else { return (0, 0) }
        switch pressedDirection {
        case .up: return (3, 0)
        case .down: return (-3, 0)
        case .right: return (0, 3)
        case .left: return (0, -3)
        }
    }

    private func wedge(_ direction: PadDirection) -> some View {
        let shape = WedgeShape(centerDegrees: direction.degrees)
        let chevronOffset = diameter * HaloMetrics.chevronRadius
        return RemotePressButton(
            direction.title,
            fire: .touchDownRepeating,
            hitShape: shape,
            onPressChange: { pressed in
                if pressed {
                    pressedDirection = direction
                } else if pressedDirection == direction {
                    pressedDirection = nil
                }
            },
            action: { isRepeat in send(direction.command, isRepeat) },
            label: { pressed in
                ZStack {
                    shape.fill(pressed ? RemoteTheme.discPressed : Color.clear)
                    Image(systemName: direction.symbol)
                        .font(.system(size: diameter * HaloMetrics.chevronSize, weight: .bold))
                        .foregroundStyle(RemoteTheme.label)
                        .scaleEffect(pressed && !reduceMotion ? 0.92 : 1)
                        .offset(
                            x: direction.unit.width * chevronOffset,
                            y: direction.unit.height * chevronOffset
                        )
                }
                .frame(width: diameter, height: diameter)
                .animation(RemoteMotion.press(isDown: pressed, reduceMotion: reduceMotion), value: pressed)
            }
        )
    }

    private var okButton: some View {
        let okSize = diameter * HaloMetrics.okDiameter
        let isOKLive = isLive || isTVOff
        return RemotePressButton(
            isTVOff ? "Turn TV On" : "Select",
            hitShape: Circle(),
            action: { _ in send(isTVOff ? .power : .ok, false) },
            label: { pressed in
                ZStack {
                    // OK is text, so this crossfades. A symbol effect needs two symbols.
                    if isTVOff {
                        Image(systemName: "power")
                            .font(.system(size: okSize * 0.38, weight: .bold))
                            .transition(okTransition)
                    } else {
                        Text(verbatim: "OK")
                            .font(.system(size: okSize * 0.3, weight: .bold, design: .rounded))
                            .transition(okTransition)
                    }
                }
                .foregroundStyle(Color.black)
                .frame(width: okSize, height: okSize)
                .background(isTVOff ? RemoteTheme.ember : RemoteTheme.phosphor, in: Circle())
                .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
                .animation(RemoteMotion.press(isDown: pressed, reduceMotion: reduceMotion), value: pressed)
                .animation(RemoteMotion.slot(reduceMotion: reduceMotion), value: isTVOff)
            }
        )
        .opacity(isOKLive ? 1 : RemoteTheme.dimmedOpacity)
        .disabled(!isOKLive)
    }

    private var okTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8))
    }
}

/// The capsule on the ring at 6 o'clock. The parent caps its type at xxxLarge, and
/// `textScale` has to read that cap from the environment, so the cap can't live here.
private struct HaloReadout: View {
    let diameter: CGFloat
    let status: TVStatus
    let isDimmed: Bool
    let isLive: Bool
    let send: (RemoteCommand, _ isRepeat: Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    /// A max of 0 means an external device owns the volume, so a number would mislead.
    private var level: Int? {
        status.volumeFraction == nil ? nil : status.volumeLevel
    }

    private var digitSize: CGFloat {
        diameter * HaloMetrics.digitSize
    }

    var body: some View {
        content
            .padding(.horizontal, diameter * 0.05)
            .frame(maxHeight: .infinity)
            .background(RemoteTheme.background, in: Capsule())
            // Sits on the Down wedge's edge, so touches must pass through to it.
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Volume")
            .accessibilityValue(spokenValue)
            .accessibilityAdjustableAction { direction in
                guard isLive else { return }
                if direction == .increment {
                    send(.volumeUp, false)
                } else if direction == .decrement {
                    send(.volumeDown, false)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if status.isMuted {
            HStack(spacing: 4) {
                Image(systemName: "speaker.slash.fill")
                Text("Muted")
            }
            .font(.system(size: min(digitSize, diameter * 0.07 * textScale), weight: .semibold, design: .rounded))
            .foregroundStyle(RemoteTheme.amber)
            .lineLimit(1)
        } else if let level {
            Text(verbatim: "\(level)")
                .font(.system(size: digitSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(RemoteTheme.label)
                .opacity(isDimmed ? 0.5 : 1)
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(level)))
                .animation(RemoteMotion.level(reduceMotion: reduceMotion), value: level)
        } else {
            Text(verbatim: "--")
                .font(.system(size: digitSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(RemoteTheme.secondaryText(contrast))
        }
    }

    private var spokenValue: String {
        if status.isMuted { return "Muted" }
        guard let level, let max = status.volumeMax else { return "Unknown" }
        return "\(level) of \(max)"
    }
}
