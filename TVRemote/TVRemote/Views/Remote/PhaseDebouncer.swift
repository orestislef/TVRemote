import Observation
import SwiftUI

/// Holds back non-connected UI for 600 ms so a quick reconnect doesn't flash.
/// `shown` is nil until the first phase has been on screen long enough.
@Observable
final class PhaseDebouncer {
    private(set) var shown: ConnectionPhase?

    @ObservationIgnored private var target: ConnectionPhase?
    @ObservationIgnored private var pending: Task<Void, Never>?

    func update(to phase: ConnectionPhase) {
        guard needsQuietPeriod(for: phase) else {
            show(phase)
            return
        }
        target = phase
        // An earlier wait keeps its deadline, or a flapping phase would never show.
        guard pending == nil else { return }
        pending = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return
            }
            guard let self, let target = self.target else { return }
            self.pending = nil
            self.shown = target
        }
    }

    /// Shows the phase straight away, for a view that is just appearing.
    func show(_ phase: ConnectionPhase) {
        cancel()
        shown = phase
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        target = nil
    }

    private func needsQuietPeriod(for phase: ConnectionPhase) -> Bool {
        if phase.isConnected { return false }
        guard let shown else { return true }
        // Leaving connected may be brief. Disconnect is the user's own action, and
        // moves between waiting phases answer something they are already watching.
        return shown.isConnected && phase != .idle
    }
}
