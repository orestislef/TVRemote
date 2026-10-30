import SwiftUI

/// When a press sends its command.
enum PressFire {
    case touchDown
    case touchDownRepeating
    case touchUp
}

nonisolated private struct PressesFireOnReleaseKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set inside a scroll view. A control that reacts to touch-down would send keys
    /// from a swipe that only meant to scroll, and could block the scroll.
    nonisolated var pressesFireOnRelease: Bool {
        get { self[PressesFireOnReleaseKey.self] }
        set { self[PressesFireOnReleaseKey.self] = newValue }
    }
}

/// Reports a touch from the moment it lands, which `Button` can't do. Every way a
/// touch can end reaches `onEnd` exactly once: release, sliding off, the system
/// cancelling the gesture, the control being disabled or removed, or the scene
/// leaving the foreground.
struct PressTracker: ViewModifier {
    var onBegin: () -> Void
    var onEnd: (_ releasedInside: Bool) -> Void

    private enum Touch {
        case idle
        case pressed
        /// The finger is still down but this press no longer counts.
        case abandoned
    }

    private static let slideOffDistance: CGFloat = 40

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var isTouching = false
    @State private var touch = Touch.idle
    @State private var pressCount = 0

    func body(content: Content) -> some View {
        content
            .gesture(drag)
            .onChange(of: isTouching) { _, touching in
                guard !touching, touch != .idle else { return }
                // GestureState also resets when the system cancels, and then onEnded
                // never runs. Wait a beat because the order of the two isn't defined.
                let press = pressCount
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    if press == pressCount { finish(releasedInside: false) }
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { abandon() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { abandon() }
            }
            .onDisappear {
                finish(releasedInside: false)
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, touching, _ in
                touching = true
            }
            .onChanged { value in
                switch touch {
                case .idle:
                    begin()
                case .pressed:
                    let moved = value.translation
                    let limit = Self.slideOffDistance
                    if moved.width * moved.width + moved.height * moved.height > limit * limit {
                        abandon()
                    }
                case .abandoned:
                    break
                }
            }
            .onEnded { _ in
                // A very quick tap can end without a change callback.
                if touch == .idle { begin() }
                finish(releasedInside: touch == .pressed)
            }
    }

    private func begin() {
        guard isEnabled else { return }
        touch = .pressed
        pressCount &+= 1
        onBegin()
    }

    private func abandon() {
        guard touch == .pressed else { return }
        touch = isTouching ? .abandoned : .idle
        onEnd(false)
    }

    private func finish(releasedInside: Bool) {
        let wasPressed = touch == .pressed
        touch = .idle
        if wasPressed { onEnd(releasedInside) }
    }
}

/// The same control as a real `Button`, which already knows how to share a touch
/// with a scroll view.
private struct ReleasePressStyle<Face: View, HitShape: Shape>: ButtonStyle {
    let hitShape: HitShape
    let onPressChange: ((Bool) -> Void)?
    let face: (Bool) -> Face

    func makeBody(configuration: Configuration) -> some View {
        face(configuration.isPressed)
            .contentShape(hitShape)
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChange?(isPressed)
            }
    }
}

/// A remote control that can fire on touch-down and repeat while held. The hit
/// area is exactly `hitShape`, so overlapping wedges line up with what is drawn.
struct RemotePressButton<Label: View, HitShape: Shape>: View {
    private let title: String
    private let fire: PressFire
    private let hitShape: HitShape
    private let value: String?
    private let isSelected: Bool
    private let onPressChange: ((Bool) -> Void)?
    private let action: (_ isRepeat: Bool) -> Void
    private let label: (_ isPressed: Bool) -> Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.pressesFireOnRelease) private var firesOnRelease
    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    init(
        _ title: String,
        fire: PressFire = .touchUp,
        hitShape: HitShape,
        value: String? = nil,
        isSelected: Bool = false,
        onPressChange: ((Bool) -> Void)? = nil,
        action: @escaping (_ isRepeat: Bool) -> Void,
        @ViewBuilder label: @escaping (_ isPressed: Bool) -> Label
    ) {
        self.title = title
        self.fire = fire
        self.hitShape = hitShape
        self.value = value
        self.isSelected = isSelected
        self.onPressChange = onPressChange
        self.action = action
        self.label = label
    }

    @ViewBuilder
    private var control: some View {
        if firesOnRelease {
            Button {
                action(false)
            } label: {
                EmptyView()
            }
            .buttonStyle(ReleasePressStyle(hitShape: hitShape, onPressChange: onPressChange, face: label))
        } else {
            label(isPressed)
                .contentShape(hitShape)
                .modifier(PressTracker(
                    onBegin: { pressBegan() },
                    onEnd: { pressEnded(releasedInside: $0) }
                ))
        }
    }

    var body: some View {
        control
            .contentShape(.accessibility, hitShape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(value ?? "")
            .accessibilityHint(isEnabled ? "" : "Not available right now")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction {
                if isEnabled { action(false) }
            }
    }

    private func pressBegan() {
        isPressed = true
        onPressChange?(true)
        switch fire {
        case .touchUp:
            break
        case .touchDown:
            action(false)
        case .touchDownRepeating:
            action(false)
            startRepeating()
        }
    }

    private func pressEnded(releasedInside: Bool) {
        repeatTask?.cancel()
        repeatTask = nil
        isPressed = false
        onPressChange?(false)
        if releasedInside, case .touchUp = fire {
            action(false)
        }
    }

    private func startRepeating() {
        repeatTask?.cancel()
        repeatTask = Task {
            let start = ContinuousClock.now
            do {
                try await Task.sleep(for: .milliseconds(350))
                while !Task.isCancelled {
                    action(true)
                    let isFast = ContinuousClock.now - start > .milliseconds(1500)
                    try await Task.sleep(for: .milliseconds(isFast ? 110 : 180))
                }
            } catch {
                // Cancelled by release, the only way out of the loop.
            }
        }
    }
}
