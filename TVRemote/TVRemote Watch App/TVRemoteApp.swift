import SwiftUI

@main
struct TVRemote_Watch_AppApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = WatchSessionManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: scenePhase, initial: true) { oldPhase, newPhase in
                    if newPhase == .active {
                        WatchSessionManager.shared.appDidBecomeActive()
                    } else if oldPhase == .active {
                        WatchSessionManager.shared.appDidResignActive()
                    }
                }
        }
    }
}
