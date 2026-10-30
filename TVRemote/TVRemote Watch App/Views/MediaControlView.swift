import CoreGraphics
import SwiftUI

/// Transport, mute and channel keys in a grid that fits a 41mm screen without
/// scrolling. Volume stays on the crown, with its level in the header.
struct MediaControlView: View {
    let phase: ConnectionPhase
    let status: TVStatus
    let crown: VolumeCrown
    let isSelected: Bool
    let press: KeyPress

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.colorSchemeContrast) private var contrast

    private let spacing: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let headerHeight = max(16, proxy.size.height * 0.09)
            let dotsClearance = proxy.size.height * 0.07
            let available = proxy.size.height - headerHeight - 2 - spacing * 2 - dotsClearance
            let cell = CGSize(
                width: (proxy.size.width - spacing * 2) / 3,
                height: max(44, available / 3)
            )

            VStack(spacing: 2) {
                header
                    .frame(height: headerHeight)
                    .padding(.horizontal, spacing)
                    .accessibilitySortPriority(1)

                Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                    GridRow {
                        key("Previous", .previous, "backward.end.fill", cell)
                        playOrWakeKey(cell)
                        key("Next", .next, "forward.end.fill", cell)
                    }
                    GridRow {
                        key("Rewind", .rewind, "backward.fill", cell)
                        muteKey(cell)
                        key("Fast Forward", .fastForward, "forward.fill", cell)
                    }
                    GridRow {
                        key("Channel Down", .channelDown, "chevron.down", cell, haptic: .directionDown, repeats: true)
                        Text("CH")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(RemoteTheme.secondaryText(contrast))
                            .accessibilityHidden(true)
                        key("Channel Up", .channelUp, "chevron.up", cell, haptic: .directionUp, repeats: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .ignoresSafeArea(edges: [.horizontal, .bottom])
    }

    private var isLive: Bool {
        phase.isConnected && !status.isTVOff
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            Text(leadingText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(leadingColor)
                .lineLimit(1)
            Spacer(minLength: 4)
            readout
                .volumeAccessibility(crown)
        }
    }

    private var leadingText: String {
        switch phase {
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .idle, .failed: return "Not connected"
        case .connected:
            return status.isTVOff ? "TV is off" : (status.appName ?? "")
        }
    }

    private var leadingColor: Color {
        if phase == .reconnecting { return RemoteTheme.amber }
        if status.isTVOff { return RemoteTheme.ember }
        return phase.isConnected ? RemoteTheme.label : RemoteTheme.secondaryText(contrast)
    }

    private var readout: some View {
        HStack(spacing: 3) {
            if status.isMuted {
                Image(systemName: "speaker.slash.fill")
                    .foregroundStyle(RemoteTheme.amber)
            } else if let level = crown.displayLevel {
                Text("\(level)")
                    .contentTransition(.numericText(value: Double(level)))
            } else {
                Text("--")
            }
        }
        .font(.system(.caption2, design: .rounded, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(RemoteTheme.label)
        .opacity(phase.isConnected ? 1 : 0.5)
        .animation(isLuminanceReduced ? nil : .snappy, value: crown.displayLevel)
    }

    // MARK: - Keys

    private func key(
        _ title: String,
        _ command: RemoteCommand,
        _ symbol: String,
        _ cell: CGSize,
        haptic: Haptic = .click,
        repeats: Bool = false
    ) -> some View {
        RemoteKey(title: title, command: command, haptic: haptic, repeats: repeats, press: press) { isPressed in
            KeyFace(shape: Capsule(), isPressed: isPressed) {
                glyph(symbol, cell)
            }
        }
        .frame(width: cell.width, height: cell.height)
        .opacity(isLive ? 1 : 0.35)
        .disabled(!isLive)
    }

    // With the TV off the middle key wakes it, so that double tap and the visible
    // key keep meaning the same thing on this page too.
    @ViewBuilder
    private func playOrWakeKey(_ cell: CGSize) -> some View {
        if status.isTVOff && phase.isConnected {
            RemoteKey(title: "Turn TV On", command: .power, haptic: .start, press: press) { isPressed in
                KeyFace(shape: Capsule(), tint: RemoteTheme.ember, isPressed: isPressed) {
                    glyph("power", cell)
                }
            }
            .frame(width: cell.width, height: cell.height)
            .handGestureShortcut(.primaryAction, isEnabled: isSelected)
        } else {
            RemoteKey(title: "Play or Pause", command: .playPause, press: press) { isPressed in
                KeyFace(shape: Capsule(), tint: RemoteTheme.phosphor, isPressed: isPressed) {
                    glyph("playpause.fill", cell)
                }
            }
            .frame(width: cell.width, height: cell.height)
            .handGestureShortcut(.primaryAction, isEnabled: isSelected && isLive)
            .opacity(isLive ? 1 : 0.35)
            .disabled(!isLive)
        }
    }

    private func muteKey(_ cell: CGSize) -> some View {
        RemoteKey(title: "Mute", command: .mute, press: press) { isPressed in
            KeyFace(shape: Capsule(), tint: status.isMuted ? RemoteTheme.amber : nil, isPressed: isPressed) {
                glyph(status.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", cell)
            }
        }
        .frame(width: cell.width, height: cell.height)
        .opacity(isLive ? 1 : 0.35)
        .disabled(!isLive)
    }

    private func glyph(_ symbol: String, _ cell: CGSize) -> some View {
        Image(systemName: symbol)
            .font(.system(size: min(cell.width, cell.height) * 0.36, weight: .semibold))
    }
}
