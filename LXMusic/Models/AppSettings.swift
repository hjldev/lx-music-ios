import Foundation

/// Playback mode matching `appSetting['player.togglePlayMethod']` in `src/common/defaultSetting.ts`.
enum PlayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case listLoop
    case random
    case list
    case singleLoop
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .listLoop: return "列表循环"
        case .random: return "随机播放"
        case .list: return "顺序播放"
        case .singleLoop: return "单曲循环"
        case .none: return "播完暂停"
        }
    }

    var systemImage: String {
        switch self {
        case .listLoop: return "repeat"
        case .random: return "shuffle"
        case .list: return "text.line.first.and.arrowtriangle.forward"
        case .singleLoop: return "repeat.1"
        case .none: return "stop.circle"
        }
    }

    var next: PlayMode {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .listLoop }
        return all[(idx + 1) % all.count]
    }
}

/// Mode for displaying lyrics on iOS Lock Screen.
enum LockScreenLyricMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case titleAndArtwork
    case titleOnly
    case artworkOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .titleAndArtwork: return "标题与海报封面（双重）"
        case .titleOnly: return "仅标题滚动"
        case .artworkOnly: return "仅海报封面滚动"
        }
    }
}

/// Persistent app settings modeled directly after `src/common/defaultSetting.ts`.
struct AppSettings: Codable, Equatable, Sendable {
    // Player
    var playQuality: AudioQuality = .k320
    var playMode: PlayMode = .listLoop
    var playbackRate: Double = 1.0
    var autoSkipOnError: Bool = true
    var allowAutoSwitchSource: Bool = true
    var isAutoCleanPlayedList: Bool = false
    var waitPlayEndStop: Bool = true

    // Lyrics
    var isShowLyricTranslation: Bool = true
    var isPlayLxlrc: Bool = true
    var lyricFontSize: Double = 18.0

    // Status Bar & Lock Screen Lyrics
    var enableStatusBarLyric: Bool = true
    var enableLockScreenLyric: Bool = true
    var lockScreenLyricMode: LockScreenLyricMode = .titleAndArtwork
    var lockScreenLyricLines: Int = 3

    // Custom Source
    var activeUserApiId: String? = nil

    // UI Preferences
    var defaultSearchScope: SearchSourceScope = .all
    var defaultDiscoverSource: MusicSource = .kw
    var defaultLeaderboardSource: MusicSource = .kw
}
