import SwiftUI

/// Holds back a drop from connected for 600 ms, so a blip doesn't flash the UI.
/// Everything else shows at once: a recovery should not wait, and neither should
/// a failure after the screen already says it's trying.
struct PhaseDebounce: ViewModifier {
    let phase: ConnectionPhase
    @Binding var shown: ConnectionPhase

    func body(content: Content) -> some View {
        content.task(id: phase) {
            guard phase != shown else { return }
            if shown.isConnected && !phase.isConnected {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
            }
            shown = phase
        }
    }
}
