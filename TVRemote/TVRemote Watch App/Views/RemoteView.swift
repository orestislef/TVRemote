import Accessibility
import CoreGraphics
import Foundation
import SwiftUI

private enum RemotePage: Hashable {
    case remote, media
}

/// Remote page geometry, all from the page's own size. The Halo is centered on the
/// page's horizontal axis, and Back and Home take the corners the circle leaves free.
private struct RemoteLayout {
    let metrics: HaloMetrics
    let haloCenter: CGPoint
    let cornerDiameter: CGFloat
    let backCenter: CGPoint
    let homeCenter: CGPoint
    let capsuleMaxWidth: CGFloat

    /// Touch area of a corner key. The keys are drawn smaller to clear the Halo.
    let cornerHitSize: CGFloat = 44

    init(size: CGSize) {
        let diameter = min(size.width * 0.88, size.height * 0.84)
        let centerY = 2 + diameter / 2
        let inset = { (keyDiameter: CGFloat) in keyDiameter / 2 + diameter * 0.04 }

        // A taller toolbar leaves less room, so shrink until the key clears the
        // ring. The inset also keeps it inside the screen's rounded corner.
        var keyDiameter = min(44, diameter * 0.235)
        while keyDiameter > 24 {
            let dx = size.width / 2 - inset(keyDiameter)
            let dy = size.height - inset(keyDiameter) - centerY
            if (dx * dx + dy * dy).squareRoot() >= diameter / 2 + keyDiameter / 2 + 2 { break }
            keyDiameter -= 1
        }

        let cornerInset = inset(keyDiameter)
        metrics = HaloMetrics(diameter: diameter)
        haloCenter = CGPoint(x: size.width / 2, y: centerY)
        cornerDiameter = keyDiameter
        backCenter = CGPoint(x: cornerInset, y: size.height - cornerInset)
        homeCenter = CGPoint(x: size.width - cornerInset, y: size.height - cornerInset)
        capsuleMaxWidth = size.width - 2 * (cornerInset + keyDiameter / 2 + 2)
    }
}

struct RemoteView: View {
    let session: WatchSessionManager

    @State private var crown: VolumeCrown
    @State private var page = RemotePage.remote
    @State private var shownPhase: ConnectionPhase
    /// When the screen started showing a wait, for the "after visible wait" haptic.
    @State private var busySince: Date?
    @State private var holdHintRequest = 0
    @State private var isHoldHintVisible = false

    init(session: WatchSessionManager) {
        self.session = session
        let phase = session.status.phase
        _crown = State(initialValue: VolumeCrown(session: session))
        _shownPhase = State(initialValue: phase)
        _busySince = State(initialValue: phase.isBusy ? Date() : nil)
    }

    var body: some View {
        // Not a Group: its modifiers can bind per branch, and these must see the swap.
        ZStack {
            if let failure = shownPhase.failure {
                FailedView(
                    failure: failure,
                    onRetry: {
                        Haptic.retry.play()
                        session.retry()
                    },
                    onMyTVs: { session.disconnect() }
                )
            } else {
                pages
            }
        }
        .modifier(PhaseDebounce(phase: session.status.phase, shown: $shownPhase))
        .onChange(of: shownPhase) { oldPhase, newPhase in
            phaseDidChange(from: oldPhase, to: newPhase)
        }
        .onChange(of: session.commandFailureCount) {
            Haptic.failure.play()
        }
        .onChange(of: session.status.volumeLevel) { _, level in
            crown.tvReported(level)
        }
        .onChange(of: isVolumeLive) { _, isLive in
            if !isLive { crown.reset() }
        }
        .onChange(of: session.status.isTVOff) { _, isOff in
            if isOff { announce("TV is off") }
        }
        .onDisappear { crown.reset() }
    }

    private var isVolumeLive: Bool {
        shownPhase.isConnected && !session.status.isTVOff
    }

    // MARK: - Pages

    private var pages: some View {
        TabView(selection: $page) {
            remotePage
                .tag(RemotePage.remote)
            mediaPage
                .tag(RemotePage.media)
        }
        .tabViewStyle(.page)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PowerButton(
                    isTVOff: session.status.isTVOff,
                    press: sendKey,
                    onHoldHint: { holdHintRequest += 1 }
                )
                .disabled(!shownPhase.isConnected)
            }
        }
        .overlay(alignment: .top) {
            if isHoldHintVisible {
                Text("Hold to turn off")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(RemoteTheme.label)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(RemoteTheme.discPressed))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .task(id: holdHintRequest) {
            guard holdHintRequest > 0 else { return }
            withAnimation(.easeOut(duration: 0.15)) { isHoldHintVisible = true }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { isHoldHintVisible = false }
        }
    }

    private var remotePage: some View {
        GeometryReader { proxy in
            let layout = RemoteLayout(size: proxy.size)

            ZStack {
                HaloPad(
                    metrics: layout.metrics,
                    phase: shownPhase,
                    status: session.status,
                    crown: crown,
                    isDoubleTapEnabled: page == .remote && shownPhase.isConnected,
                    capsuleMaxWidth: layout.capsuleMaxWidth,
                    press: sendKey
                )
                .position(layout.haloCenter)
                .accessibilitySortPriority(1)

                cornerKey("Back", .back, "arrow.uturn.backward", layout)
                    .position(layout.backCenter)

                cornerKey("TV Home", .home, "house.fill", layout)
                    .position(layout.homeCenter)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .accessibilityElement(children: .contain)
        }
        .ignoresSafeArea(edges: [.horizontal, .bottom])
        .modifier(CrownVolumeInput(crown: crown, isActive: page == .remote && isVolumeLive))
    }

    private var mediaPage: some View {
        MediaControlView(
            phase: shownPhase,
            status: session.status,
            crown: crown,
            isSelected: page == .media,
            press: sendKey
        )
        .modifier(CrownVolumeInput(crown: crown, isActive: page == .media && isVolumeLive))
    }

    private func cornerKey(
        _ title: String,
        _ command: RemoteCommand,
        _ symbol: String,
        _ layout: RemoteLayout
    ) -> some View {
        RemoteKey(title: title, command: command, press: sendKey) { isPressed in
            KeyFace(shape: Circle(), isPressed: isPressed) {
                Image(systemName: symbol)
                    .font(.system(size: layout.cornerDiameter * 0.42, weight: .semibold))
            }
            .frame(width: layout.cornerDiameter, height: layout.cornerDiameter)
            .frame(width: layout.cornerHitSize, height: layout.cornerHitSize)
            .contentShape(Circle())
        }
        .frame(width: layout.cornerHitSize, height: layout.cornerHitSize)
        .opacity(isVolumeLive ? 1 : 0.35)
        .disabled(!isVolumeLive)
    }

    // MARK: - Actions

    private func sendKey(_ command: RemoteCommand, _ haptic: Haptic?) {
        if session.send(command) {
            haptic?.play()
        } else {
            Haptic.failure.play()
        }
    }

    private func phaseDidChange(from oldPhase: ConnectionPhase, to newPhase: ConnectionPhase) {
        switch newPhase {
        case .connected:
            if let busySince, Date().timeIntervalSince(busySince) >= 0.6 {
                Haptic.success.play()
            }
            announce("Connected")
        case .connecting:
            announce("Connecting")
        case .reconnecting:
            Haptic.notification.play()
            announce("Reconnecting")
        case .failed(let failure):
            Haptic.failure.play()
            announce(failure.title)
        case .idle:
            break
        }

        if !newPhase.isBusy {
            busySince = nil
        } else if !oldPhase.isBusy {
            busySince = Date()
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
