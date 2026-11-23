import Foundation

/// Raw lyrics returned by Music SDKs and cached on disk (matching `LX.Music.LyricInfo`).
struct LyricInfo: Codable, Hashable, Sendable {
    var lyric: String
    var tlyric: String?
    var lxlyric: String?

    init(lyric: String, tlyric: String? = nil, lxlyric: String? = nil) {
        self.lyric = lyric
        self.tlyric = tlyric
        self.lxlyric = lxlyric
    }

    var isEmpty: Bool {
        lyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One word / syllable token parsed from `<start,duration>text` in `lxlyric`.
struct LyricWordToken: Identifiable, Hashable, Sendable {
    let id: Int
    /// Start time in milliseconds relative to the owning line's `timeMs`.
    let startMs: Int
    /// Duration in milliseconds.
    let durationMs: Int
    let text: String
}

/// One parsed synchronized lyric line with optional word tokens and aligned translation lines.
struct ParsedLyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    /// Line start timestamp in milliseconds (with LRC `[offset:...]` already applied during playback comparison).
    let timeMs: Int
    /// Plain lyric line text (without `<start,duration>` tags).
    let text: String
    /// Word-by-word karaoke tokens if `lxlyric` was available for this line.
    let words: [LyricWordToken]
    /// Aligned translation lines sharing this timestamp.
    let extendedLyrics: [String]

    var hasWordTiming: Bool { !words.isEmpty }
}

/// Complete parsed lyric document ready for real-time rendering.
struct ParsedLyricDocument: Hashable, Sendable {
    let offsetMs: Int
    let isWordMode: Bool
    let lines: [ParsedLyricLine]

    static let empty = ParsedLyricDocument(offsetMs: 0, isWordMode: false, lines: [])

    /// Effective visual offset matching LX Music (`+60ms` in line mode).
    var effectiveOffsetMs: Int {
        isWordMode ? offsetMs : (offsetMs + 60)
    }
}
