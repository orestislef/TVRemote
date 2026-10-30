import SwiftUI

struct FailedView: View {
    let failure: ConnectionFailure
    let onRetry: () -> Void
    let onMyTVs: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // Small buttons so both fit a 41mm screen with the usual copy. Still scrolls
        // if a long title and body outgrow it.
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: failure.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(RemoteTheme.ember)
                    .accessibilityHidden(true)

                VStack(spacing: 2) {
                    Text(failure.title)
                        .font(.headline)
                        .foregroundStyle(RemoteTheme.label)
                    Text(failure.message)
                        .font(.footnote)
                        .foregroundStyle(RemoteTheme.secondaryText(contrast))
                }
                .multilineTextAlignment(.center)
                .accessibilitySortPriority(1)

                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(RemoteTheme.phosphor)
                    .foregroundStyle(Color.black)
                    .handGestureShortcut(.primaryAction)

                Button("My TVs", action: onMyTVs)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
