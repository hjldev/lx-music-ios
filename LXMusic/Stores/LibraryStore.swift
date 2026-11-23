import Foundation
import Observation

/// Manages built-in playlists (`default` 试听列表, `love` 我的收藏), `temp` temporary playback list,
/// custom user playlists, search history, and `.lxmc` / `.json` backup import & export.
@Observable
@MainActor
final class LibraryStore {
    private(set) var defaultList: UserPlaylist
    private(set) var loveList: UserPlaylist
    private(set) var userLists: [UserPlaylist]
    private(set) var tempList: UserPlaylist
    private(set) var searchHistory: [String]

    /// All persistent visible lists (`default`, `love`, then user playlists).
    var allVisibleLists: [UserPlaylist] {
        [defaultList, loveList] + userLists
    }

    init() {
        let loaded = PersistenceStore.shared.loadPlaylists() ?? []
        self.defaultList = loaded.first(where: { $0.id == BuiltInListID.default })
            ?? UserPlaylist(id: BuiltInListID.default, name: "list__name_default", list: [])
        self.loveList = loaded.first(where: { $0.id == BuiltInListID.love })
            ?? UserPlaylist(id: BuiltInListID.love, name: "list__name_love", list: [])
        self.userLists = loaded.filter { $0.id != BuiltInListID.default && $0.id != BuiltInListID.love && $0.id != BuiltInListID.temp }
        self.tempList = UserPlaylist(id: BuiltInListID.temp, name: "临时列表", list: [])
        self.searchHistory = PersistenceStore.shared.loadSearchHistory()
    }

    private func persistPlaylists() {
        PersistenceStore.shared.savePlaylists([defaultList, loveList] + userLists)
    }

    // MARK: - Playlist Lookup

    func playlist(for id: String) -> UserPlaylist? {
        switch id {
        case BuiltInListID.default: return defaultList
        case BuiltInListID.love: return loveList
        case BuiltInListID.temp: return tempList
        default: return userLists.first(where: { $0.id == id })
        }
    }

    func tracks(in listId: String) -> [MusicInfo] {
        playlist(for: listId)?.list ?? []
    }

    func setTempList(tracks: [MusicInfo], sourceListId: String? = nil) {
        tempList = UserPlaylist(id: BuiltInListID.temp, name: "临时列表", sourceListId: sourceListId, list: tracks)
    }

    // MARK: - Favorites (`love`)

    func isLoved(_ musicInfo: MusicInfo) -> Bool {
        loveList.list.contains(where: { $0.id == musicInfo.id })
    }

    @discardableResult
    func toggleLove(_ musicInfo: MusicInfo) -> Bool {
        if let idx = loveList.list.firstIndex(where: { $0.id == musicInfo.id }) {
            loveList.list.remove(at: idx)
            persistPlaylists()
            return false
        } else {
            loveList.list.insert(musicInfo, at: 0)
            persistPlaylists()
            return true
        }
    }

    // MARK: - Custom Playlist CRUD

    @discardableResult
    func createUserPlaylist(
        name: String,
        tracks: [MusicInfo] = [],
        source: MusicSource? = nil,
        sourceListId: String? = nil
    ) -> UserPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "新建歌单" : trimmed
        let newList = UserPlaylist(
            id: "userlist_\(Int64(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 100...999))",
            name: finalName,
            source: source,
            sourceListId: sourceListId,
            locationUpdateTime: Int64(Date().timeIntervalSince1970 * 1000),
            list: LXMCBackupCodec.deduplicateSongs(tracks)
        )
        userLists.append(newList)
        persistPlaylists()
        return newList
    }

    func renameUserPlaylist(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = userLists.firstIndex(where: { $0.id == id }) else { return }
        userLists[idx].name = trimmed
        persistPlaylists()
    }

    func deleteUserPlaylist(id: String) {
        userLists.removeAll { $0.id == id }
        persistPlaylists()
    }

    func moveUserPlaylists(from source: IndexSet, to destination: Int) {
        userLists.move(fromOffsets: source, toOffset: destination)
        persistPlaylists()
    }

    // MARK: - Track Mutations

    func addTracks(_ tracks: [MusicInfo], to listId: String, atTop: Bool = false) {
        mutateList(id: listId) { list in
            let existingIds = Set(list.map(\.id))
            let fresh = tracks.filter { !existingIds.contains($0.id) }
            if atTop {
                list.insert(contentsOf: fresh, at: 0)
            } else {
                list.append(contentsOf: fresh)
            }
        }
    }

    func removeTracks(ids: Set<String>, from listId: String) {
        mutateList(id: listId) { list in
            list.removeAll { ids.contains($0.id) }
        }
    }

    func removeTracks(at offsets: IndexSet, from listId: String) {
        mutateList(id: listId) { list in
            list.remove(atOffsets: offsets)
        }
    }

    func moveTracks(in listId: String, from source: IndexSet, to destination: Int) {
        mutateList(id: listId) { list in
            list.move(fromOffsets: source, toOffset: destination)
        }
    }

    func clearTracks(in listId: String) {
        mutateList(id: listId) { list in
            list.removeAll()
        }
    }

    func overwriteTracks(_ tracks: [MusicInfo], in listId: String) {
        mutateList(id: listId) { list in
            list = LXMCBackupCodec.deduplicateSongs(tracks)
        }
    }

    func updateTrackPic(musicId: String, picUrl: String) {
        func patch(_ list: inout [MusicInfo]) -> Bool {
            var changed = false
            for i in list.indices where list[i].id == musicId && list[i].meta.picUrl != picUrl {
                list[i].meta.picUrl = picUrl
                changed = true
            }
            return changed
        }
        var anyChanged = false
        if patch(&defaultList.list) { anyChanged = true }
        if patch(&loveList.list) { anyChanged = true }
        for i in userLists.indices {
            if patch(&userLists[i].list) { anyChanged = true }
        }
        _ = patch(&tempList.list)
        if anyChanged {
            persistPlaylists()
        }
    }

    /// Syncs a user playlist that is linked to an online songlist (`source` + `sourceListId`).
    func syncOnlinePlaylist(id: String) async throws -> Int {
        guard let list = userLists.first(where: { $0.id == id }),
              let source = list.source,
              let sourceListId = list.sourceListId,
              let sdk = MusicSDKRegistry.shared.sdk(for: source) else {
            throw MusicSDKError.apiError("此歌单未关联在线歌单")
        }
        let firstPage = try await sdk.getSongListDetail(idOrUrl: sourceListId, page: 1)
        var allTracks = firstPage.list
        let totalPages = min(10, max(1, Int(ceil(Double(firstPage.total) / Double(max(1, firstPage.limit))))))
        if totalPages > 1 && allTracks.count < firstPage.total {
            for p in 2...totalPages {
                if let next = try? await sdk.getSongListDetail(idOrUrl: sourceListId, page: p) {
                    allTracks.append(contentsOf: next.list)
                }
            }
        }
        let deduped = LXMCBackupCodec.deduplicateSongs(allTracks)
        if let idx = userLists.firstIndex(where: { $0.id == id }) {
            userLists[idx].list = deduped
            userLists[idx].locationUpdateTime = Int64(Date().timeIntervalSince1970 * 1000)
            persistPlaylists()
        }
        return deduped.count
    }

    private func mutateList(id: String, _ transform: (inout [MusicInfo]) -> Void) {
        switch id {
        case BuiltInListID.default:
            transform(&defaultList.list)
            persistPlaylists()
        case BuiltInListID.love:
            transform(&loveList.list)
            persistPlaylists()
        case BuiltInListID.temp:
            transform(&tempList.list)
        default:
            if let idx = userLists.firstIndex(where: { $0.id == id }) {
                transform(&userLists[idx].list)
                persistPlaylists()
            }
        }
    }

    // MARK: - Search History

    func addSearchHistory(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0 == trimmed }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > 30 {
            searchHistory = Array(searchHistory.prefix(30))
        }
        PersistenceStore.shared.saveSearchHistory(searchHistory)
    }

    func removeSearchHistory(_ keyword: String) {
        searchHistory.removeAll { $0 == keyword }
        PersistenceStore.shared.saveSearchHistory(searchHistory)
    }

    func clearSearchHistory() {
        searchHistory = []
        PersistenceStore.shared.saveSearchHistory([])
    }

    // MARK: - Backup Import / Export (`.lxmc` / `.json`)

    func importBackup(data: Data) throws -> Int {
        let result = try LXMCBackupCodec.importBackupData(data)
        var importedCount = 0

        for incoming in result.playlists {
            importedCount += incoming.list.count
            if incoming.id == BuiltInListID.default {
                defaultList.list = incoming.list
            } else if incoming.id == BuiltInListID.love {
                loveList.list = incoming.list
            } else if let idx = userLists.firstIndex(where: { $0.id == incoming.id }) {
                userLists[idx].list = incoming.list
            } else {
                var newPl = incoming
                if newPl.id.isEmpty || newPl.id == BuiltInListID.temp {
                    newPl.id = "userlist_\(Int64(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 100...999))"
                }
                userLists.append(newPl)
            }
        }
        persistPlaylists()
        return importedCount
    }

    func exportAllBackupData() throws -> Data {
        try LXMCBackupCodec.exportAllPlaylistsLXMC(allVisibleLists)
    }
}
