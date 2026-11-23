import Foundation

/// Online and local music sources matching LX Music Desktop (`src/common/types/common.d.ts`).
enum MusicSource: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case kw
    case kg
    case tx
    case wy
    case mg
    case local

    var id: String { rawValue }

    /// The five active online music sources in LX Music's canonical order.
    static let onlineSources: [MusicSource] = [.kw, .kg, .tx, .wy, .mg]

    var displayName: String {
        switch self {
        case .kw: return "酷我音乐"
        case .kg: return "酷狗音乐"
        case .tx: return "QQ音乐"
        case .wy: return "网易音乐"
        case .mg: return "咪咕音乐"
        case .local: return "本地音乐"
        }
    }

    var shortName: String {
        switch self {
        case .kw: return "酷我"
        case .kg: return "酷狗"
        case .tx: return "QQ"
        case .wy: return "网易"
        case .mg: return "咪咕"
        case .local: return "本地"
        }
    }

    var badgeTag: String {
        rawValue.uppercased()
    }
}

/// Search scope including aggregated ("all") search across all 5 online sources.
enum SearchSourceScope: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case kw
    case kg
    case tx
    case wy
    case mg

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "聚合"
        case .kw: return "酷我"
        case .kg: return "酷狗"
        case .tx: return "QQ"
        case .wy: return "网易"
        case .mg: return "咪咕"
        }
    }

    var musicSource: MusicSource? {
        MusicSource(rawValue: rawValue)
    }
}

/// Audio quality identifiers matching LX Music Desktop (`LX.Quality`).
enum AudioQuality: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case k128 = "128k"
    case k192 = "192k"
    case k320 = "320k"
    case ape = "ape"
    case flac = "flac"
    case flac24bit = "flac24bit"
    case wav = "wav"

    var id: String { rawValue }

    /// Standard selectable online qualities in settings.
    static let selectableQualities: [AudioQuality] = [.k128, .k320, .flac, .flac24bit]

    /// Quality fallback priority order matching `TRY_QUALITYS_LIST` in `core/music/utils.ts`.
    static let downgradeOrder: [AudioQuality] = [.flac24bit, .flac, .k320]

    var displayName: String {
        switch self {
        case .k128: return "标准 (128k)"
        case .k192: return "较高 (192k)"
        case .k320: return "高品 (320k)"
        case .ape: return "无损 (APE)"
        case .flac: return "无损 (FLAC)"
        case .flac24bit: return "Hi-Res (24bit)"
        case .wav: return "母带 (WAV)"
        }
    }

    var badgeText: String {
        switch self {
        case .k128: return "SD"
        case .k192: return "192K"
        case .k320: return "HQ"
        case .ape: return "APE"
        case .flac: return "SQ"
        case .flac24bit: return "HR"
        case .wav: return "WAV"
        }
    }

    var sortRank: Int {
        switch self {
        case .k128: return 1
        case .k192: return 2
        case .k320: return 3
        case .ape: return 4
        case .flac: return 5
        case .flac24bit: return 6
        case .wav: return 7
        }
    }

    /// Migrates legacy `flac32bit` string to `flac24bit` just like `fixNewMusicInfoQuality`.
    static func fromRawMigrated(_ raw: String) -> AudioQuality? {
        if raw == "flac32bit" { return .flac24bit }
        return AudioQuality(rawValue: raw)
    }
}
