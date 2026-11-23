import SwiftUI

@main
struct LXMusicApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(env)
                .environment(env.settingsStore)
                .environment(env.libraryStore)
                .environment(env.dislikeStore)
                .environment(env.userApiStore)
                .environment(env.player)
        }
    }
}
