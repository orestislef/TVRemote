import SwiftUI

@main
struct TVRemoteApp: App {
    @State private var tvManager: TVManager
    @State private var showSplash = true
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Here and not in onAppear: a Watch message can wake the app with no scene,
        // and the session manager has to be able to answer it.
        let manager = TVManager()
        _tvManager = State(initialValue: manager)
        PhoneSessionManager.shared.tvManager = manager
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(tvManager)
                    .opacity(showSplash ? 0 : 1)

                if showSplash {
                    SplashView {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            showSplash = false
                        }
                    }
                    .transition(.opacity)
                }
            }
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                switch newPhase {
                case .active:
                    tvManager.appDidBecomeActive()
                case .background:
                    tvManager.appDidEnterBackground()
                default:
                    break
                }
            }
        }
    }
}
