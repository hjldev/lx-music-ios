import Foundation

/// Online and local music sources (Kuwo only + local).
enum MusicSource: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case kw
    case local

    var id: String { rawValue }

    /// Active online music sources.
    static let onlineSources: [MusicSource] = [.kw]

    var displayName: String {
        switch self {
        case .kw: return "酷我音乐"
        case .local: return "本地音乐"
        }
    }

    var shortName: String {
        switch self {
        case .kw: return "酷我"
        case .local: return "本地"
        }
    }

    var badgeTag: String {
        rawValue.uppercased()
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

    /// Resolves the highest available quality supported by both the track and active custom source (`getPlayQuality`).
    static func resolvePlayQuality(
        preferred: AudioQuality,
        musicInfo: MusicInfo,
        supportedBySource: [AudioQuality]
    ) -> AudioQuality {
        let downgrade = AudioQuality.downgradeOrder // [flac24bit, flac, 320k]
        if let startIdx = downgrade.firstIndex(of: preferred) {
            for candidate in downgrade[startIdx...] {
                if musicInfo.hasQuality(candidate) && supportedBySource.contains(candidate) {
                    return candidate
                }
            }
        }
        return .k128
    }
}
