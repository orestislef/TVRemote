import Foundation
import SwiftUI

/// Turning the TV off takes a .5 s hold, so a stray tap can't do it. A tap only
/// explains that, unless the TV is off, when it wakes it. VoiceOver skips the hold.
struct PowerButton: View {
    let isTVOff: Bool
    let press: KeyPress
    let onHoldHint: () -> Void

    @State private var progress = 0.0
    @State private var pressStartedAt: Date?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        Image(systemName: "power")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(isLuminanceReduced ? RemoteTheme.secondary : RemoteTheme.ember)
            .frame(width: 30, height: 30)
            .background {
                if isLuminanceReduced {
                    Circle().stroke(RemoteTheme.secondary, lineWidth: 1)
                } else {
                    Circle().fill(RemoteTheme.disc)
                }
            }
            .overlay {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(RemoteTheme.ember, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            // Drawn at 30 to fit the toolbar, touched at 38.
            .frame(width: 38, height: 38)
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.35)
            .onLongPressGesture(
                minimumDuration: 0.5,
                maximumDistance: 24,
                perform: { fire() },
                onPressingChanged: { pressingChanged($0) }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isTVOff ? "Turn TV On" : "Turn TV Off")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { fire() }
    }

    private func fire() {
        press(.power, isTVOff ? .start : .stop)
    }

    private func pressingChanged(_ isPressing: Bool) {
        if isPressing {
            pressStartedAt = Date()
            withAnimation(.linear(duration: 0.5)) { progress = 1 }
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { progress = 0 }

        // Whether this comes before or after perform isn't documented, so the
        // press length decides what a tap is, not a flag set by perform.
        let held = pressStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        pressStartedAt = nil
        guard held < 0.45 else { return }
        if isTVOff {
            fire()
        } else {
            onHoldHint()
        }
    }
}
