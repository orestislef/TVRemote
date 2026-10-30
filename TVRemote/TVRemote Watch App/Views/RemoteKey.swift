import Foundation
import SwiftUI

/// Sends a command and plays the haptic if it went out. The haptic is nil for
/// the repeats in a hold that stay silent.
typealias KeyPress = @MainActor (RemoteCommand, Haptic?) -> Void

/// Repeats a key while held: 350 ms delay, every 180 ms, then 110 ms after 1.5 s.
final class HoldRepeater {
    private var task: Task<Void, Never>?
    /// True once a hold has fired, so the touch-up doesn't send one more.
    private var didRepeat = false

    func begin(_ tick: @escaping (Int) -> Void) {
        task?.cancel()
        didRepeat = false
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            let startedAt = Date()
            var count = 0
            while !Task.isCancelled {
                self?.didRepeat = true
                count += 1
                tick(count)
                let isFast = Date().timeIntervalSince(startedAt) >= 1.5
                try? await Task.sleep(for: .milliseconds(isFast ? 110 : 180))
            }
        }
    }

    func end() {
        task?.cancel()
        task = nil
    }

    /// Reads the flag and clears it, so a later VoiceOver activation still fires.
    func consumeRepeat() -> Bool {
        defer { didRepeat = false }
        return didRepeat
    }
}

private struct PressStyle<Face: View>: ButtonStyle {
    let face: (Bool) -> Face
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        face(configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChange(isPressed)
            }
    }
}

/// A remote key: fires on touch-up, optionally repeats while held. The face draws
/// the whole key and owns the content shape, so wedges can hit test as wedges.
struct RemoteKey<Face: View>: View {
    let title: String
    let command: RemoteCommand
    var haptic: Haptic? = .click
    var repeats = false
    let press: KeyPress
    @ViewBuilder let face: (Bool) -> Face

    @State private var repeater = HoldRepeater()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            if !repeater.consumeRepeat() {
                press(command, haptic)
            }
        } label: {
            EmptyView()
        }
        .buttonStyle(PressStyle(face: face, onPressChange: { pressChanged($0) }))
        .accessibilityLabel(title)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { repeater.end() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { repeater.end() }
        }
        .onDisappear { repeater.end() }
    }

    private func pressChanged(_ isPressed: Bool) {
        guard repeats else { return }
        if isPressed {
            repeater.begin { count in
                press(command, count % 3 == 0 ? .click : nil)
            }
        } else {
            repeater.end()
        }
    }
}

/// Standard key look. A tint means a filled key with a black glyph. Always-On
/// drops the fill for a thin outline.
struct KeyFace<KeyShape: Shape, Glyph: View>: View {
    let shape: KeyShape
    var tint: Color? = nil
    let isPressed: Bool
    @ViewBuilder let glyph: () -> Glyph

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        glyph()
            .foregroundStyle(glyphColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isLuminanceReduced {
                    shape.stroke(RemoteTheme.secondary, lineWidth: 1)
                } else {
                    shape.fill(fillColor)
                    if contrast == .increased {
                        shape.stroke(Color.white.opacity(0.4), lineWidth: 1)
                    }
                }
            }
            .contentShape(shape)
    }

    private var glyphColor: Color {
        if isLuminanceReduced { return RemoteTheme.secondary }
        return tint == nil ? RemoteTheme.label : Color.black
    }

    private var fillColor: Color {
        if let tint { return isPressed ? tint.opacity(0.75) : tint }
        return isPressed ? RemoteTheme.discPressed : RemoteTheme.disc
    }
}
