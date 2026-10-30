import Foundation
import Observation
import SwiftUI

/// Turns crown detents into volume keys. One detent is one key, sent at most
/// every 120 ms. The readout runs ahead of the TV on what has been queued or sent.
@Observable
final class VolumeCrown {
    private let session: WatchSessionManager

    /// Keys waiting to go out, signed. Opposite detents cancel each other.
    private var queued = 0
    /// Keys sent that the TV hasn't reported back yet, signed.
    private var sent = 0
    private(set) var isTurning = false

    @ObservationIgnored private var isAtLimit = false
    @ObservationIgnored private var lastReported: Int?
    @ObservationIgnored private var lastSendAt = Date.distantPast
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var turningTask: Task<Void, Never>?

    private let sendInterval: TimeInterval = 0.12
    private let pendingCap = 6

    init(session: WatchSessionManager) {
        self.session = session
        lastReported = session.status.volumeLevel
    }

    /// Reported plus pending, or nil when the TV gives no usable volume.
    var displayLevel: Int? {
        let status = session.status
        guard let level = status.volumeLevel, let top = status.volumeMax, top > 0 else { return nil }
        return min(top, max(0, level + queued + sent))
    }

    var displayFraction: Double? {
        guard let level = displayLevel, let top = session.status.volumeMax else { return nil }
        return Double(level) / Double(top)
    }

    var spokenValue: String {
        if session.status.isMuted { return "Muted" }
        guard let level = displayLevel, let top = session.status.volumeMax else { return "Unknown" }
        return "\(level) of \(top)"
    }

    func turn(by detents: Int) {
        guard detents != 0, canSend else { return }
        isTurning = true
        turningTask?.cancel()
        turningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.isTurning = false
        }
        for _ in 0..<abs(detents) {
            step(detents > 0 ? 1 : -1)
        }
    }

    /// One key up or down. Also what VoiceOver's adjustable action calls.
    func step(_ sign: Int) {
        guard canSend else { return }
        if isLimit(sign) {
            if !isAtLimit {
                isAtLimit = true
                Haptic.click.play()
            }
            return
        }
        guard abs(queued + sign) <= pendingCap else { return }
        isAtLimit = false
        queued += sign
        drain()
    }

    /// A new report from the TV. Only the keys it has caught up with come off, so
    /// the readout doesn't jump back while more are still on the way.
    func tvReported(_ level: Int?) {
        defer { lastReported = level }
        guard let level, let lastReported else {
            sent = 0
            return
        }
        let moved = level - lastReported
        if sent > 0 {
            sent = max(0, sent - max(0, moved))
        } else if sent < 0 {
            sent = min(0, sent - min(0, moved))
        }
    }

    func reset() {
        drainTask?.cancel()
        drainTask = nil
        reconcileTask?.cancel()
        queued = 0
        sent = 0
        isAtLimit = false
    }

    private var canSend: Bool {
        session.status.phase.isConnected && !session.status.isTVOff
    }

    /// With no known volume there is no limit to stop at, so keys still go out.
    private func isLimit(_ sign: Int) -> Bool {
        let status = session.status
        guard let level = status.volumeLevel, let top = status.volumeMax, top > 0 else { return false }
        let projected = level + queued + sent
        return sign > 0 ? projected >= top : projected <= 0
    }

    private func drain() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.queued != 0 else { break }
                let wait = self.sendInterval - Date().timeIntervalSince(self.lastSendAt)
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                    continue
                }
                let sign = self.queued > 0 ? 1 : -1
                self.queued -= sign
                self.lastSendAt = Date()
                guard self.session.send(sign > 0 ? .volumeUp : .volumeDown) else {
                    Haptic.failure.play()
                    self.queued = 0
                    break
                }
                self.sent += sign
                self.scheduleReconcile()
            }
            // After a reset the handle may already belong to a newer task.
            if !Task.isCancelled { self?.drainTask = nil }
        }
    }

    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.sent = 0
        }
    }
}

/// Binds the crown to volume on one page-level container. Each page has its own,
/// because the crown only follows the focused view.
struct CrownVolumeInput: ViewModifier {
    private let crown: VolumeCrown
    private let isActive: Bool

    @State private var value = 0.0
    @State private var lastDetent = 0
    @FocusState private var isFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(crown: VolumeCrown, isActive: Bool) {
        self.crown = crown
        self.isActive = isActive
    }

    func body(content: Content) -> some View {
        // focusable must come before digitalCrownRotation or the crown does nothing.
        content
            .focusable(isActive)
            .focused($isFocused)
            .digitalCrownRotation(
                detent: $value,
                from: -10000,
                through: 10000,
                by: 1,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true,
                onChange: { _ in },
                onIdle: { recenterIfNeeded() }
            )
            .digitalCrownAccessory(.hidden)
            .focusEffectDisabled()
            .onChange(of: value) { _, newValue in
                let detent = Int(newValue.rounded())
                let delta = detent - lastDetent
                lastDetent = detent
                if isActive { crown.turn(by: delta) }
            }
            // Pages and the wrist can both take focus away, and nothing documents
            // when. Ask again whenever it should be here and isn't, a few times,
            // since a request made during a page change can be ignored.
            .task(id: needsFocus) {
                guard needsFocus else { return }
                for _ in 0..<5 {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    isFocused = true
                }
            }
    }

    private var needsFocus: Bool {
        isActive && scenePhase == .active && !isFocused
    }

    /// Keeps the value away from the stops. lastDetent moves first so that the
    /// jump doesn't count as turning.
    private func recenterIfNeeded() {
        guard abs(value) > 5000 else { return }
        lastDetent = 0
        value = 0
    }
}

extension View {
    /// The VoiceOver side of the Halo: label, value and swipe to adjust.
    func volumeAccessibility(_ crown: VolumeCrown) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel("Volume")
            .accessibilityValue(crown.spokenValue)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: crown.step(1)
                case .decrement: crown.step(-1)
                @unknown default: break
                }
            }
    }
}
