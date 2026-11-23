import Foundation

/// Well-known built-in playlist identifiers matching `LIST_IDS` in `src/common/constants.ts`.
enum BuiltInListID {
    static let `default` = "default"
    static let love = "love"
    static let temp = "temp"
}

/// User-created or built-in playlist container (matching `LX.List.UserListInfoFull`).
struct UserPlaylist: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var source: MusicSource?
    var sourceListId: String?
    var locationUpdateTime: Int64?
    var list: [MusicInfo]

    var isBuiltIn: Bool {
        id == BuiltInListID.default || id == BuiltInListID.love || id == BuiltInListID.temp
    }

    var displayName: String {
        switch id {
        case BuiltInListID.default:
            return (name == "list__name_default" || name.isEmpty) ? "试听列表" : name
        case BuiltInListID.love:
            return (name == "list__name_love" || name.isEmpty) ? "我的收藏" : name
        case BuiltInListID.temp:
            return name.isEmpty ? "临时列表" : name
        default:
            return name
        }
    }

    init(
        id: String,
        name: String,
        source: MusicSource? = nil,
        sourceListId: String? = nil,
        locationUpdateTime: Int64? = nil,
        list: [MusicInfo] = []
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.sourceListId = sourceListId
        self.locationUpdateTime = locationUpdateTime
        self.list = list
    }
}

/// Online songlist summary item shown in SongList Square & SongList Search.
struct OnlineSongListItem: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var author: String
    var img: String?
    var playCount: String?
    var desc: String?
    var total: Int?
    var time: String?
    var source: MusicSource

    var uniqueKey: String { "\(source.rawValue)_\(id)" }
}

/// Online songlist detailed metadata header.
struct OnlineSongListInfo: Hashable, Sendable {
    var name: String
    var img: String?
    var desc: String?
    var author: String?
    var playCount: String?
}

/// Paginated response for an online songlist detail view.
struct SongListDetailPage: Sendable {
    var list: [MusicInfo]
    var page: Int
    var limit: Int
    var total: Int
    var source: MusicSource
    var info: OnlineSongListInfo
}

/// Paginated response for online songlist square or search.
struct SongListSearchPage: Sendable {
    var list: [OnlineSongListItem]
    var page: Int
    var limit: Int
    var total: Int
    var source: MusicSource
}

/// Paginated response for online music search.
struct MusicSearchPage: Sendable {
    var list: [MusicInfo]
    var page: Int
    var allPage: Int
    var limit: Int
    var total: Int
    var source: MusicSource
}

/// Sort option for SongList Square.
struct SongListSortOption: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
}

/// Tag item for SongList Square filtering.
struct SongListTagItem: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var parentId: String?
    var parentName: String?
    var source: MusicSource
}

/// Categorized tag group for SongList Square.
struct SongListTagGroup: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var list: [SongListTagItem]
}

/// Tags bundle returned by `songList.getTags()`.
struct SongListTagsResult: Sendable {
    var hotTag: [SongListTagItem]
    var tags: [SongListTagGroup]
    var source: MusicSource
}

/// Leaderboard entry matching `{ id, name, bangid, source }`.
struct LeaderboardBoard: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var bangid: String
    var source: MusicSource
}

/// Paginated leaderboard tracks result.
struct LeaderboardPage: Sendable {
    var list: [MusicInfo]
    var page: Int
    var limit: Int
    var total: Int
    var source: MusicSource
}
