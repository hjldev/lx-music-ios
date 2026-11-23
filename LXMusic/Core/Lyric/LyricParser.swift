import Foundation

/// Exact port of `src/common/utils/lyric-font-player/{index,line-player,font-player}.js` & `src/renderer/core/lyric.ts`.
enum LyricParser {

    private static let timeFieldPattern = #"^(?:\[[\d:.]+\])+"#
    private static let timeTokenPattern = #"\d{1,3}(?::\d{1,3}){0,2}(?:\.\d{1,3})?"#
    private static let wordTagPattern = #"<(\d+),(\d+)>"#
    private static let msTimePattern = #"\[\d{1,3}(?::\d{1,3}){0,2}\.\d{3}\]"#

    /// Parses raw `LyricInfo` according to user lyric display settings into a ready-to-render `ParsedLyricDocument`.
    static func parse(
        info: LyricInfo?,
        showTranslation: Bool,
        playWordByWord: Bool
    ) -> ParsedLyricDocument {
        guard let info, !info.isEmpty else { return .empty }

        let useLx = playWordByWord && !(info.lxlyric ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let mainRaw = useLx ? (info.lxlyric ?? info.lyric) : info.lyric

        var extendedRaw: [String] = []
        if showTranslation, let t = info.tlyric, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            extendedRaw.append(t)
        }

        let offsetMs = extractOffsetMs(from: mainRaw)
        let isMsTime = RegexHelper.test(msTimePattern, in: mainRaw)

        struct RawLineEntry {
            var timeMs: Int
            var rawText: String
            var extended: [String]
        }

        var mapByTimeKey: [String: RawLineEntry] = [:]
        var orderedKeys: [String] = []

        for rawLine in mainRaw.components(separatedBy: CharacterSet.newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let fieldMatch = RegexHelper.firstMatch(timeFieldPattern, in: line),
                  let timeField = fieldMatch.first else { continue }

            let text = String(line.dropFirst(timeField.count)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            let tokens = RegexHelper.allMatches(timeTokenPattern, in: timeField).compactMap(\.first)
            for token in tokens {
                let normalizedKey = normalizeTimeLabel(token)
                if mapByTimeKey[normalizedKey] != nil {
                    let cleanExt = RegexHelper.replace(wordTagPattern, in: text, with: "")
                    mapByTimeKey[normalizedKey]?.extended.append(cleanExt)
                    continue
                }
                guard let ms = parseTimestampMs(rawToken: token, isThreeDigitMs: isMsTime) else { continue }
                mapByTimeKey[normalizedKey] = RawLineEntry(timeMs: ms, rawText: text, extended: [])
                orderedKeys.append(normalizedKey)
            }
        }

        // Align translation lines by normalized timestamp (exact match, plus ±100ms tolerance fallback)
        for extRaw in extendedRaw {
            let extIsMs = RegexHelper.test(msTimePattern, in: extRaw)
            for rawLine in extRaw.components(separatedBy: CharacterSet.newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty,
                      let fieldMatch = RegexHelper.firstMatch(timeFieldPattern, in: line),
                      let timeField = fieldMatch.first else { continue }
                let text = RegexHelper.replace(wordTagPattern, in: String(line.dropFirst(timeField.count)), with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, text != "//" else { continue }

                let tokens = RegexHelper.allMatches(timeTokenPattern, in: timeField).compactMap(\.first)
                for token in tokens {
                    let key = normalizeTimeLabel(token)
                    if mapByTimeKey[key] != nil {
                        mapByTimeKey[key]?.extended.append(text)
                    } else if let extMs = parseTimestampMs(rawToken: token, isThreeDigitMs: extIsMs) {
                        // Gentle tolerance fallback when sources differ by 1-2 digits of ms padding
                        if let nearestKey = orderedKeys.min(by: {
                            abs((mapByTimeKey[$0]?.timeMs ?? 0) - extMs) < abs((mapByTimeKey[$1]?.timeMs ?? 0) - extMs)
                        }), let nearestMs = mapByTimeKey[nearestKey]?.timeMs, abs(nearestMs - extMs) <= 100 {
                            mapByTimeKey[nearestKey]?.extended.append(text)
                        }
                    }
                }
            }
        }

        let sortedEntries = mapByTimeKey.values.sorted { $0.timeMs < $1.timeMs }
        let isWordMode = !sortedEntries.isEmpty && RegexHelper.test(#"^<\d+,\d+>"#, in: sortedEntries[0].rawText)

        let parsedLines: [ParsedLyricLine] = sortedEntries.enumerated().map { idx, entry in
            let words = parseWordTokens(entry.rawText)
            let plainText = RegexHelper.replace(wordTagPattern, in: entry.rawText, with: "")
            return ParsedLyricLine(
                id: idx,
                timeMs: entry.timeMs,
                text: plainText,
                words: words,
                extendedLyrics: entry.extended
            )
        }

        return ParsedLyricDocument(offsetMs: offsetMs, isWordMode: isWordMode, lines: parsedLines)
    }

    /// Binary search for the active lyric line index at `currentTimeMs`.
    static func activeLineIndex(in document: ParsedLyricDocument, atMs currentTimeMs: Int) -> Int? {
        let lines = document.lines
        guard !lines.isEmpty else { return nil }
        let adjusted = currentTimeMs + document.effectiveOffsetMs

        if adjusted < lines[0].timeMs { return nil }
        var low = 0
        var high = lines.count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].timeMs <= adjusted {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    /// Computes karaoke highlight progress (`0.0 ... 1.0`) for a single word token at `currentTimeMs`.
    static func wordProgress(line: ParsedLyricLine, word: LyricWordToken, atMs currentTimeMs: Int, offsetMs: Int) -> Double {
        let elapsedInLine = (currentTimeMs + offsetMs) - line.timeMs
        if elapsedInLine <= word.startMs { return 0.0 }
        let dur = max(1, word.durationMs)
        let progress = Double(elapsedInLine - word.startMs) / Double(dur)
        return min(max(progress, 0.0), 1.0)
    }

    // MARK: - Internal Helpers

    private static func extractOffsetMs(from lyric: String) -> Int {
        guard let m = RegexHelper.firstMatch(#"\[offset:([^\]]*)\]"#, in: lyric, options: .caseInsensitive),
              m.count >= 2 else { return 0 }
        return Int(m[1].trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private static func normalizeTimeLabel(_ label: String) -> String {
        var s = RegexHelper.replace(#"^0+(\d+)"#, in: label, with: "$1")
        s = RegexHelper.replace(#":0+(\d+)"#, in: s, with: ":$1")
        s = RegexHelper.replace(#"\.0+(\d+)"#, in: s, with: ".$1")
        return s
    }

    private static func parseTimestampMs(rawToken: String, isThreeDigitMs: Bool) -> Int? {
        let colonParts = rawToken.components(separatedBy: ":")
        guard colonParts.count <= 3 else { return nil }
        var padded = colonParts
        while padded.count < 3 { padded.insert("0", at: 0) }

        let hh = Int(padded[0]) ?? 0
        let mm = Int(padded[1]) ?? 0
        let secParts = padded[2].components(separatedBy: ".")
        let ss = Int(secParts[0]) ?? 0
        var ms = 0
        if secParts.count >= 2 {
            let frac = secParts[1]
            if frac.count == 3 {
                ms = Int(frac) ?? 0
            } else if frac.count == 2 {
                ms = (Int(frac) ?? 0) * (isThreeDigitMs ? 1 : 10)
            } else if frac.count == 1 {
                ms = (Int(frac) ?? 0) * (isThreeDigitMs ? 1 : 100)
            } else {
                ms = Int(String(frac.prefix(3))) ?? 0
            }
        }
        return hh * 3_600_000 + mm * 60_000 + ss * 1_000 + ms
    }

    private static func parseWordTokens(_ rawText: String) -> [LyricWordToken] {
        guard let regex = try? NSRegularExpression(pattern: wordTagPattern) else { return [] }
        let ns = rawText as NSString
        let matches = regex.matches(in: rawText, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        var tokens: [LyricWordToken] = []
        tokens.reserveCapacity(matches.count)
        for i in 0..<matches.count {
            let m = matches[i]
            let startMs = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let durMs = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let textStart = m.range.location + m.range.length
            let textEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            let text = ns.substring(with: NSRange(location: textStart, length: max(0, textEnd - textStart)))
            tokens.append(LyricWordToken(id: i, startMs: startMs, durationMs: durMs, text: text))
        }
        return tokens
    }
}
