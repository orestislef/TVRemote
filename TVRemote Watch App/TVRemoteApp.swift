import SwiftUI

@main
struct TVRemote_Watch_AppApp: App {
    init() {
        _ = WatchSessionManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
