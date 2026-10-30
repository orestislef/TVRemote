import CoreGraphics
import SwiftUI

/// The signature control: a 280-degree volume gauge around the D-pad, with the
/// readout capsule sitting in the gauge's gap at 6 o'clock.
struct HaloPad: View {
    let metrics: HaloMetrics
    let phase: ConnectionPhase
    let status: TVStatus
    let crown: VolumeCrown
    let isDoubleTapEnabled: Bool
    let capsuleMaxWidth: CGFloat
    let press: KeyPress

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            ring
                .accessibilityHidden(true)

            DPadView(
                metrics: metrics,
                mode: padMode,
                isDoubleTapEnabled: isDoubleTapEnabled,
                press: press
            )

            capsule
                .offset(y: metrics.ringRadius)
                .allowsHitTesting(false)
                .volumeAccessibility(crown)
                .accessibilitySortPriority(1)
        }
        .frame(width: metrics.diameter, height: metrics.diameter)
        .transaction { transaction in
            if isLuminanceReduced { transaction.animation = nil }
        }
    }

    private var padMode: PadMode {
        guard phase.isConnected else { return .dimmed }
        return status.isTVOff ? .tvOff : .live
    }

    // MARK: - Ring

    private var ring: some View {
        ZStack {
            if phase == .connecting && !reduceMotion && !isLuminanceReduced {
                PulsingTrack(metrics: metrics, lineWidth: ringWidth)
            } else {
                HaloArc(metrics: metrics, fraction: 1, color: trackColor, lineWidth: ringWidth)
            }

            if let fraction = crown.displayFraction, fraction > 0 {
                HaloArc(metrics: metrics, fraction: fraction, color: arcColor, lineWidth: ringWidth)
                    .opacity(arcOpacity)
            }
        }
        .opacity(isLuminanceReduced ? 0.6 : 1)
        .animation(.snappy, value: crown.displayFraction)
        .animation(.easeOut(duration: 0.2), value: ringWidth)
    }

    private var ringWidth: CGFloat {
        let grows = crown.isTurning && !reduceMotion && !isLuminanceReduced
        return metrics.ringStroke * (grows ? 1.3 : 1)
    }

    private var trackColor: Color {
        Color.white.opacity(contrast == .increased ? 0.28 : 0.14)
    }

    private var arcColor: Color {
        status.isMuted ? RemoteTheme.amber : RemoteTheme.phosphor
    }

    private var arcOpacity: Double {
        guard phase.isConnected else { return 0.5 }
        return status.isMuted || status.isTVOff ? 0.35 : 1
    }

    // MARK: - Capsule

    private var capsule: some View {
        capsuleContent
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, metrics.diameter * 0.05)
            .frame(height: metrics.capsuleHeight)
            .background(Capsule().fill(RemoteTheme.background))
            .frame(maxWidth: capsuleMaxWidth)
    }

    @ViewBuilder
    private var capsuleContent: some View {
        switch phase {
        case .connecting:
            caption("Connecting…", color: RemoteTheme.secondaryText(contrast))
        case .reconnecting:
            caption("Reconnecting…", color: RemoteTheme.amber)
        case .idle, .failed:
            caption("Not connected", color: RemoteTheme.secondaryText(contrast))
        case .connected(let route):
            if status.isTVOff {
                caption("TV is off", color: RemoteTheme.ember)
            } else if status.isMuted {
                HStack(spacing: metrics.diameter * 0.02) {
                    Image(systemName: "speaker.slash.fill")
                    Text("Muted")
                }
                .font(.system(size: metrics.captionSize, weight: .semibold, design: .rounded))
                .foregroundStyle(RemoteTheme.amber)
            } else {
                digits(route: route)
            }
        }
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: metrics.captionSize, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
    }

    private func digits(route: ConnectionRoute) -> some View {
        HStack(spacing: metrics.diameter * 0.02) {
            if route == .viaPhone {
                Image(systemName: "iphone")
                    .font(.system(size: metrics.captionSize, weight: .semibold))
                    .foregroundStyle(RemoteTheme.secondaryText(contrast))
            }
            if let level = crown.displayLevel {
                Text("\(level)")
                    .contentTransition(.numericText(value: Double(level)))
            } else {
                Text("--")
            }
        }
        .font(.system(size: metrics.digitSize, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(RemoteTheme.label)
    }
}

/// An arc along the ring from the gap's left edge, clockwise. Starts at 130
/// degrees: 6 o'clock is 90, and the 80-degree gap is centered on it.
private struct HaloArc: View {
    let metrics: HaloMetrics
    let fraction: Double
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        Circle()
            .trim(from: 0, to: 280.0 / 360.0 * fraction)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(130))
            .frame(width: metrics.ringRadius * 2, height: metrics.ringRadius * 2)
    }
}

/// Track that breathes between 14 and 28 percent while connecting. Its own view
/// so the repeating animation stops by leaving the hierarchy.
private struct PulsingTrack: View {
    let metrics: HaloMetrics
    let lineWidth: CGFloat

    @State private var isBright = false

    var body: some View {
        HaloArc(metrics: metrics, fraction: 1, color: .white, lineWidth: lineWidth)
            .opacity(isBright ? 0.28 : 0.14)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isBright = true
                }
            }
    }
}
