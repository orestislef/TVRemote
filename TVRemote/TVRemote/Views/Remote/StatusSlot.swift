import SwiftUI

enum StatusSlotContent: Equatable {
    case empty
    case appChip(String)
    case notConnected
    case connecting(String)
    case connected
    case reconnecting
    case tvOff
    case hint(String)
}

/// A fixed 36 pt slot, so a status change never moves the controls. It only grows
/// at accessibility sizes, where the whole stack scrolls anyway.
struct StatusSlot: View {
    let content: StatusSlotContent
    let onConnect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var bannerTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    var body: some View {
        ZStack {
            switch content {
            case .empty:
                EmptyView()
            case .appChip(let name):
                AppChip(name: name)
                    .transition(.opacity)
            case .notConnected:
                StatusBanner {
                    Text("Not connected")
                        .foregroundStyle(RemoteTheme.label)
                    Button(action: onConnect) {
                        Text("Connect")
                            // Reaches past the text without growing the fixed-height slot.
                            .contentShape(Rectangle().inset(by: -12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RemoteTheme.phosphor)
                }
                .transition(bannerTransition)
            case .connecting(let name):
                StatusBanner {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting to \(name)…")
                        .foregroundStyle(RemoteTheme.label)
                        .truncationMode(.middle)
                }
                .transition(bannerTransition)
            case .connected:
                StatusBanner {
                    Circle()
                        .fill(RemoteTheme.green)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text("Connected")
                        .foregroundStyle(RemoteTheme.label)
                }
                .transition(bannerTransition)
            case .reconnecting:
                StatusBanner {
                    Text("Reconnecting…")
                        .foregroundStyle(RemoteTheme.amber)
                }
                .transition(bannerTransition)
            case .tvOff:
                StatusBanner {
                    Text("TV is off")
                        .foregroundStyle(RemoteTheme.ember)
                }
                .transition(bannerTransition)
            case .hint(let text):
                StatusBanner {
                    Text(text)
                        .foregroundStyle(RemoteTheme.label)
                }
                .transition(bannerTransition)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 36)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? nil : 36)
        .animation(RemoteMotion.slot(reduceMotion: reduceMotion), value: content)
    }
}

/// Glass, or opaque disc fill under Reduce Transparency.
private struct StatusBanner<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let banner = HStack(spacing: 8) {
            content()
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 16)
        .frame(minHeight: 36)

        if reduceTransparency {
            banner
                .background(RemoteTheme.disc, in: Capsule())
                .contrastStroke(Capsule())
        } else {
            banner
                .glassEffect(.regular, in: .capsule)
        }
    }
}

private struct AppChip: View {
    let name: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.tv.fill")
                .accessibilityHidden(true)
            Text(name)
                .contentTransition(.opacity)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(RemoteTheme.label)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background(RemoteTheme.disc, in: Capsule())
        .contrastStroke(Capsule())
        .animation(.easeInOut(duration: 0.2), value: name)
    }
}

// MARK: - Failed copy

/// Why the connection gave up and what to do next. Sits inside the disc, or in the
/// scrolling stack at accessibility sizes where the disc can't hold the text.
struct FailedPanel: View {
    let failure: ConnectionFailure
    var fitsDisc = true
    let onRetry: () -> Void
    let onMyTVs: () -> Void
    let onPairAgain: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    /// Retrying can't fix these two, so the button that can takes the prominent spot.
    private var fixAction: (title: String, action: () -> Void)? {
        switch failure {
        case .needsPairing: return ("Pair Again", onPairAgain)
        case .localNetworkDenied: return ("Open Settings", onOpenSettings)
        default: return nil
        }
    }

    private var typeRange: ClosedRange<DynamicTypeSize> {
        DynamicTypeSize.xSmall...(fitsDisc ? DynamicTypeSize.xLarge : DynamicTypeSize.accessibility5)
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: failure.symbol)
                .font(.system(size: 28))
                .foregroundStyle(RemoteTheme.ember)
                .accessibilityHidden(true)
            Text(failure.title)
                .font(.headline)
                .foregroundStyle(RemoteTheme.label)
                .accessibilityAddTraits(.isHeader)
            Text(failure.message)
                .font(.footnote)
                .foregroundStyle(RemoteTheme.secondaryText(contrast))
                .padding(.bottom, 4)

            primaryButton

            secondaryButtons
        }
        .multilineTextAlignment(.center)
        .minimumScaleFactor(fitsDisc ? 0.85 : 1)
        .dynamicTypeSize(typeRange)
    }

    private var primaryAction: () -> Void {
        fixAction?.action ?? onRetry
    }

    private var primaryButton: some View {
        Button(action: primaryAction) {
            Text(fixAction?.title ?? "Try Again")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.black)
        }
        .buttonStyle(.glassProminent)
        .tint(RemoteTheme.phosphor)
        .controlSize(fitsDisc ? .small : .regular)
    }

    private var secondaryButtons: some View {
        let layout = fitsDisc ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 4))
        return layout {
            if fixAction != nil {
                secondaryButton("Try Again", action: onRetry)
            }
            secondaryButton("My TVs", action: onMyTVs)
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RemoteTheme.label)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
