import SwiftUI
import Observation

/// Root dependency container injected across the entire SwiftUI hierarchy.
@Observable
@MainActor
final class AppEnvironment {
    let settingsStore: SettingsStore
    let libraryStore: LibraryStore
    let dislikeStore: DislikeStore
    let userApiStore: UserApiStore
    let player: PlayerController

    var showFullPlayer: Bool = false
    var showPlayQueue: Bool = false
    var trackPendingAddToPlaylist: [MusicInfo]? = nil
    var trackPendingSourceSwitch: MusicInfo? = nil
    var toastMessage: String? = nil
    private var toastTask: Task<Void, Never>?

    init() {
        let settings = SettingsStore()
        let library = LibraryStore()
        let dislike = DislikeStore()
        let userApi = UserApiStore(settingsStore: settings)
        let player = PlayerController(
            settingsStore: settings,
            libraryStore: library,
            dislikeStore: dislike,
            userApiStore: userApi
        )
        self.settingsStore = settings
        self.libraryStore = library
        self.dislikeStore = dislike
        self.userApiStore = userApi
        self.player = player
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }
}
