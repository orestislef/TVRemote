import Foundation
import SwiftUI
import UIKit

private let smallestPortraitDiameter: CGFloat = 180

/// iOS 26 pops on a rightward pan anywhere in the content, which is too easy to do
/// by feel on a remote in a dark room. The screen-edge swipe still goes back.
private struct ContentPopGuard: UIViewControllerRepresentable {
    final class Controller: UIViewController {
        private weak var guarded: UINavigationController?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guarded = navigationController
            guarded?.interactiveContentPopGestureRecognizer?.isEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guarded?.interactiveContentPopGestureRecognizer?.isEnabled = true
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}
}

/// The remote: a volume knob with a D-pad inside, and everything else kept quiet.
/// Fits one screen without scrolling from SE to Pro Max, in both orientations.
struct PhoneRemoteView: View {
    let device: TVDevice

    private enum SlotTransient: Equatable {
        case connected
        case hint(String)
    }

    @Environment(TVManager.self) private var tvManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true

    @State private var debouncer = PhaseDebouncer()
    @State private var transient: SlotTransient?
    /// Restarts the timer even when the same hint is shown twice.
    @State private var transientRequest = 0
    @State private var pulse = HapticPulse()
    @State private var limitHapticPlayed = false
    @State private var showRepair = false

    /// Follows address changes the manager picked up after this view was pushed.
    private var currentDevice: TVDevice {
        tvManager.pairedDevices.first { $0.id == device.id } ?? device
    }

    private var isActiveDevice: Bool {
        tvManager.activeDevice?.id == device.id
    }

    private var devicePhase: ConnectionPhase {
        tvManager.phase(for: device)
    }

    private var isConnected: Bool {
        isActiveDevice && devicePhase.isConnected
    }

    /// Another TV's volume and app must never show under this TV's name.
    private var status: TVStatus {
        isActiveDevice ? tvManager.status : TVStatus()
    }

    /// Nil during the first quiet period, when the slot stays blank.
    private var displayPhase: ConnectionPhase? {
        devicePhase.isConnected ? devicePhase : debouncer.shown
    }

    private var isTVOff: Bool {
        isConnected && status.isTVOff
    }

    private var isLive: Bool {
        displayPhase?.isConnected == true && !isTVOff
    }

    private var failure: ConnectionFailure? {
        displayPhase?.failure
    }

    var body: some View {
        layout
            .background { RemoteTheme.background.ignoresSafeArea() }
            .background { ContentPopGuard().accessibilityHidden(true) }
            .environment(\.colorScheme, .dark)
            .navigationTitle(currentDevice.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(RemoteTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { toolbarItems }
            .navigationDestination(isPresented: $showRepair) {
                PairingView(device: currentDevice, isRepair: true)
            }
            .sensoryFeedback(trigger: pulse) { _, new in
                hapticsEnabled ? new.haptic.feedback : nil
            }
            .task(id: transientRequest) {
                guard transient != nil else { return }
                do {
                    try await Task.sleep(for: .milliseconds(1500))
                } catch {
                    return
                }
                transient = nil
            }
            .onAppear {
                debouncer.update(to: devicePhase)
                if !isConnected {
                    tvManager.connect(to: currentDevice)
                }
            }
            .onDisappear {
                debouncer.cancel()
            }
            .onChange(of: devicePhase) { _, phase in
                debouncer.update(to: phase)
            }
            .onChange(of: displayPhase) { old, new in
                displayPhaseChanged(from: old, to: new)
            }
            .onChange(of: isTVOff) { _, off in
                // Losing the session also clears this, and says nothing about the TV.
                if isConnected { announce(off ? "TV is off" : "TV is on") }
            }
            .onChange(of: tvManager.commandRejectionCount) {
                pulse.play(.error)
            }
    }

    // MARK: - Layout

    private var layout: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            if dynamicTypeSize.isAccessibilitySize || (width <= height && portraitFit(height: height) < smallestPortraitDiameter) {
                scrollingLayout(width: width)
            } else if width > height {
                landscapeLayout(width: width, height: height)
            } else {
                portraitLayout(width: width, height: height)
            }
        }
    }

    /// The largest Halo the portrait stack can hold: 1.04D, fixed rows 36 + 52 + 56 + 52,
    /// four gaps of at least 12, 8 + 8 padding.
    private func portraitFit(height: CGFloat) -> CGFloat {
        (height - 260) / 1.04
    }

    // Portrait SE: H 603, content 335, D 313 (1.04D = 325.5). Fixed rows 36 + 52 + 56 + 52,
    // four gaps of at least 12, 8 + 8 padding: 585.5, leaving the spacers 17.5 to share.
    // Display Zoom on an SE is shorter than the 240 floor allows, so the fit wins there.
    private func portraitLayout(width: CGFloat, height: CGFloat) -> some View {
        let contentWidth = min(width - 40, 400)
        let diameter = min(portraitFit(height: height), min(max(min(contentWidth, height * 0.52), 240), 360))
        return VStack(spacing: 0) {
            slot
                .accessibilitySortPriority(3)
            Spacer(minLength: 12)
            halo(diameter: diameter)
                .accessibilitySortPriority(2)
            Spacer(minLength: 12)
            utilityRow
            Spacer(minLength: 12)
            rocker
            Spacer(minLength: 12)
            transportRow
        }
        .frame(width: contentWidth)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    // Landscape SE: W 667, H about 331, D = min(315, 280) = 280 (1.04D = 291.2), so the
    // Halo clears the height by 40. Column 323 wide, its stack 196 + 36 gaps = 232 tall.
    private func landscapeLayout(width: CGFloat, height: CGFloat) -> some View {
        let diameter = min(height - 16, width * 0.42, height / 1.04)
        let columnWidth = min(width - diameter - 64, 440)
        return HStack(spacing: 0) {
            VStack(spacing: 12) {
                slot
                    .accessibilitySortPriority(3)
                rocker
                utilityRow
                transportRow
            }
            .frame(width: columnWidth)
            .frame(maxWidth: .infinity)

            halo(diameter: diameter)
                .accessibilitySortPriority(2)
                .padding(.trailing, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    // The one layout that scrolls: accessibility sizes, and windows too short for the
    // portrait stack. The disc can't hold large failure text, so the copy takes the
    // Halo's place here.
    private func scrollingLayout(width: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                slot
                    .accessibilitySortPriority(3)
                Group {
                    if let failure {
                        failedPanel(failure, fitsDisc: false)
                    } else {
                        halo(diameter: min(240, width - 40))
                    }
                }
                .accessibilitySortPriority(2)
                utilityRow
                rocker
                transportRow
            }
            .frame(width: min(width - 40, 400))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .environment(\.pressesFireOnRelease, true)
        }
    }

    // MARK: - Pieces

    private var slotContent: StatusSlotContent {
        guard let displayPhase else { return .empty }
        switch displayPhase {
        case .idle:
            return .notConnected
        case .connecting:
            return .connecting(currentDevice.displayName)
        case .reconnecting:
            return .reconnecting
        case .failed:
            return .empty
        case .connected:
            if isTVOff { return .tvOff }
            switch transient {
            case .connected: return .connected
            case .hint(let text): return .hint(text)
            case nil: return .appChip(status.appName ?? "Home")
            }
        }
    }

    private var slot: some View {
        StatusSlot(content: slotContent) {
            tvManager.connect(to: currentDevice)
        }
    }

    private func halo(diameter: CGFloat) -> some View {
        HaloPad(
            diameter: diameter,
            status: status,
            isReconnecting: displayPhase == .reconnecting,
            isLive: isLive,
            isTVOff: isTVOff,
            showsDiscOverlay: failure != nil,
            send: sender
        ) {
            if let failure {
                failedPanel(failure, fitsDisc: true)
            }
        }
    }

    private func failedPanel(_ failure: ConnectionFailure, fitsDisc: Bool) -> some View {
        FailedPanel(
            failure: failure,
            fitsDisc: fitsDisc,
            onRetry: { tvManager.retry() },
            onMyTVs: { dismiss() },
            onPairAgain: { showRepair = true },
            onOpenSettings: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        )
    }

    private var utilityRow: some View {
        UtilityRow(send: sender)
            .remoteControls(isLive: isLive)
    }

    private var rocker: some View {
        VolumeRocker(isMuted: status.isMuted, send: sender)
            .remoteControls(isLive: isLive)
    }

    private var transportRow: some View {
        TransportRow(send: sender)
            .remoteControls(isLive: isLive)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            PowerButton(
                isTVOff: isTVOff,
                onFire: { send(.power, isRepeat: false) },
                onTapHint: { showTransient(.hint("Hold to turn off")) }
            )
            .disabled(displayPhase?.isConnected != true)

            Menu {
                Button {
                    dismiss()
                } label: {
                    Label("Switch TV", systemImage: "tv")
                }
                Toggle(isOn: $hapticsEnabled) {
                    Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
                }
                Divider()
                Button(role: .destructive) {
                    tvManager.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .disabled(devicePhase == .idle)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    // MARK: - Actions

    private var sender: (RemoteCommand, _ isRepeat: Bool) -> Void {
        { command, isRepeat in send(command, isRepeat: isRepeat) }
    }

    private func showTransient(_ value: SlotTransient) {
        transient = value
        transientRequest += 1
    }

    private func send(_ command: RemoteCommand, isRepeat: Bool) {
        if let haptic = haptic(for: command, isRepeat: isRepeat) {
            pulse.play(haptic)
        }
        tvManager.sendCommand(command)
    }

    private func haptic(for command: RemoteCommand, isRepeat: Bool) -> RemoteHaptic? {
        switch command {
        case .volumeUp, .volumeDown:
            if !isRepeat { limitHapticPlayed = false }
            guard isAtVolumeLimit(for: command) else {
                limitHapticPlayed = false
                return .selection
            }
            // One thud at the limit, not one per repeat.
            defer { limitHapticPlayed = true }
            return limitHapticPlayed ? nil : .rigid
        case .power:
            return .heavy
        case .ok, .playPause, .mute:
            return .medium
        default:
            return isRepeat ? .selection : .soft
        }
    }

    private func isAtVolumeLimit(for command: RemoteCommand) -> Bool {
        guard let level = status.volumeLevel, let max = status.volumeMax, max > 0 else { return false }
        return command == .volumeUp ? level >= max : level <= 0
    }

    private func displayPhaseChanged(from old: ConnectionPhase?, to new: ConnectionPhase?) {
        guard let new else { return }
        switch new {
        case .connected:
            // Only after a wait the user actually saw. A silent reconnect stays silent.
            if let old, !old.isConnected, old != .idle {
                pulse.play(.success)
                showTransient(.connected)
                announce("Connected")
            }
        case .connecting:
            announce("Connecting to \(currentDevice.displayName)")
        case .reconnecting:
            pulse.play(.warning)
            announce("Reconnecting")
        case .failed(let failure):
            pulse.play(.error)
            announce("\(failure.title). \(failure.message)")
        case .idle:
            announce("Not connected")
        }
    }

    private func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

private extension View {
    func remoteControls(isLive: Bool) -> some View {
        opacity(isLive ? 1 : RemoteTheme.dimmedOpacity)
            .disabled(!isLive)
            .animation(.easeInOut(duration: 0.2), value: isLive)
    }
}
