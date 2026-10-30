import SwiftUI

private let circleSize: CGFloat = 52

/// A 52 pt round control. Back, Home, channel and transport keys are all this.
private struct RemoteCircleButton<Glyph: View>: View {
    let title: String
    var fire: PressFire = .touchUp
    var fill = RemoteTheme.disc
    var pressedFill = RemoteTheme.discPressed
    let action: (_ isRepeat: Bool) -> Void
    @ViewBuilder let glyph: () -> Glyph

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RemotePressButton(title, fire: fire, hitShape: Circle(), action: action) { pressed in
            glyph()
                // The circle is a fixed size, so past this the glyph would overflow it.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(width: circleSize, height: circleSize)
                .background(pressed ? pressedFill : fill, in: Circle())
                .contrastStroke(Circle())
                .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
                .animation(RemoteMotion.press(isDown: pressed, reduceMotion: reduceMotion), value: pressed)
        }
    }
}

// MARK: - Utility row

struct UtilityRow: View {
    let send: (RemoteCommand, _ isRepeat: Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            symbolButton("Back", symbol: "arrow.uturn.backward", command: .back)
            Spacer(minLength: 0)
            symbolButton("TV Home", symbol: "house.fill", command: .home)
            Spacer(minLength: 0)
            channelButton("Channel Down", symbol: "chevron.down", command: .channelDown)
            Spacer(minLength: 0)
            channelButton("Channel Up", symbol: "chevron.up", command: .channelUp)
        }
    }

    private func symbolButton(_ title: String, symbol: String, command: RemoteCommand) -> some View {
        RemoteCircleButton(title: title, action: { send(command, $0) }) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(RemoteTheme.label)
        }
    }

    private func channelButton(_ title: String, symbol: String, command: RemoteCommand) -> some View {
        RemoteCircleButton(title: title, fire: .touchDownRepeating, action: { send(command, $0) }) {
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.footnote.weight(.bold))
                Text(verbatim: "CH")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(RemoteTheme.label)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
        }
    }
}

// MARK: - Volume rocker

/// Minus, Mute and plus as thirds of one capsule.
struct VolumeRocker: View {
    let isMuted: Bool
    let send: (RemoteCommand, _ isRepeat: Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            segment("Volume Down", fire: .touchDownRepeating, command: .volumeDown) {
                Image(systemName: "minus")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(RemoteTheme.label)
            }
            segment("Mute", fire: .touchUp, command: .mute, isSelected: isMuted) {
                Text("Mute")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isMuted ? RemoteTheme.amber : RemoteTheme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
            }
            segment("Volume Up", fire: .touchDownRepeating, command: .volumeUp) {
                Image(systemName: "plus")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(RemoteTheme.label)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(Capsule())
        .contrastStroke(Capsule())
    }

    private func segment<Glyph: View>(
        _ title: String,
        fire: PressFire,
        command: RemoteCommand,
        isSelected: Bool = false,
        @ViewBuilder glyph: @escaping () -> Glyph
    ) -> some View {
        RemotePressButton(
            title,
            fire: fire,
            hitShape: Rectangle(),
            isSelected: isSelected,
            action: { send(command, $0) },
            label: { pressed in
                glyph()
                    .frame(maxWidth: .infinity, minHeight: 56, maxHeight: .infinity)
                    .background(pressed ? RemoteTheme.discPressed : RemoteTheme.disc)
                    .animation(RemoteMotion.press(isDown: pressed, reduceMotion: reduceMotion), value: pressed)
            }
        )
    }
}

// MARK: - Transport

struct TransportRow: View {
    let send: (RemoteCommand, _ isRepeat: Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            key("Previous", symbol: "backward.end.fill", command: .previous)
            Spacer(minLength: 0)
            key("Rewind", symbol: "backward.fill", command: .rewind)
            Spacer(minLength: 0)
            RemoteCircleButton(
                title: "Play or Pause",
                fill: RemoteTheme.phosphor,
                pressedFill: RemoteTheme.phosphor.opacity(0.75),
                action: { send(.playPause, $0) }
            ) {
                Image(systemName: "playpause.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.black)
            }
            Spacer(minLength: 0)
            key("Fast Forward", symbol: "forward.fill", command: .fastForward)
            Spacer(minLength: 0)
            key("Next", symbol: "forward.end.fill", command: .next)
        }
    }

    private func key(_ title: String, symbol: String, command: RemoteCommand) -> some View {
        RemoteCircleButton(title: title, action: { send(command, $0) }) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(RemoteTheme.label)
        }
    }
}

// MARK: - Power

/// Hold 0.5 s to turn off, so a stray tap can't kill the movie. A tap only explains
/// that. When the TV is already off a tap wakes it, and VoiceOver activates directly.
struct PowerButton: View {
    let isTVOff: Bool
    let onFire: () -> Void
    let onTapHint: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var progress: CGFloat = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var didFire = false

    var body: some View {
        Image(systemName: "power")
            .font(.body.weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .foregroundStyle(isEnabled ? RemoteTheme.ember : RemoteTheme.secondary)
            .frame(width: 36, height: 36)
            .overlay {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(RemoteTheme.ember, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2)
            }
            // Drawn at 36, touched at 44.
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .modifier(PressTracker(
                onBegin: { pressBegan() },
                onEnd: { pressEnded(releasedInside: $0) }
            ))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isTVOff ? "Turn TV On" : "Turn TV Off")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if isEnabled { onFire() }
            }
    }

    private func pressBegan() {
        guard !isTVOff else { return }
        didFire = false
        withAnimation(.linear(duration: 0.5)) { progress = 1 }
        holdTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            didFire = true
            onFire()
            clearProgress()
        }
    }

    private func pressEnded(releasedInside: Bool) {
        holdTask?.cancel()
        holdTask = nil
        if didFire {
            didFire = false
            return
        }
        clearProgress()
        guard releasedInside else { return }
        if isTVOff {
            onFire()
        } else {
            onTapHint()
        }
    }

    private func clearProgress() {
        withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
    }
}
