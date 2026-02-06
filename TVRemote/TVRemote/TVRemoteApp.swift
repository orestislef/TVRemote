import SwiftUI

@main
struct TVRemoteApp: App {
    @State private var tvManager = TVManager()
    @State private var showSplash = true

    init() {
        _ = PhoneSessionManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(tvManager)
                    .onAppear {
                        PhoneSessionManager.shared.tvManager = tvManager
                    }
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
        }
    }
}
