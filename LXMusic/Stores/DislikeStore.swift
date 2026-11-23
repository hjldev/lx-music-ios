import Foundation
import Observation

/// Exact 1:1 port of LX Music Desktop's dislike list engine (`src/renderer/store/dislikeList/action.ts`).
/// Rule syntax (newline-separated):
/// - `song@singer`: exact song + singer
/// - `song`: exact song title (any singer)
/// - `@singer`: exact singer name (any song)
/// - Note: `#` is the escape alias for a literal `@` in song/singer names (NOT a comment prefix).
@Observable
@MainActor
final class DislikeStore {
    private(set) var rulesText: String = ""
    private(set) var musicNames: Set<String> = []
    private(set) var singerNames: Set<String> = []
    private(set) var exactPairs: Set<String> = []

    var ruleCount: Int {
        musicNames.count + singerNames.count + exactPairs.count
    }

    var ruleLines: [String] {
        rulesText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    init() {
        let saved = PersistenceStore.shared.loadDislikeRules()
        applyRules(saved, persist: false)
    }

    nonisolated static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "@", with: "#")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hasDislike(_ musicInfo: MusicInfo) -> Bool {
        let name = Self.normalize(musicInfo.name)
        let singer = Self.normalize(musicInfo.singer)
        return musicNames.contains(name)
            || singerNames.contains(singer)
            || exactPairs.contains("\(name)@\(singer)")
    }

    func addDislike(musicInfo: MusicInfo) {
        addDislike(name: musicInfo.name, singer: musicInfo.singer)
    }

    func addDislike(name: String, singer: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = singer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty || !s.isEmpty else { return }

        let line: String
        if !n.isEmpty && !s.isEmpty {
            line = "\(n.replacingOccurrences(of: "@", with: "#"))@\(s.replacingOccurrences(of: "@", with: "#"))"
        } else if !n.isEmpty {
            line = n.replacingOccurrences(of: "@", with: "#")
        } else {
            line = "@\(s.replacingOccurrences(of: "@", with: "#"))"
        }

        let updated = rulesText.isEmpty ? line : "\(rulesText)\n\(line)"
        applyRules(updated, persist: true)
    }

    func removeRule(_ rule: String) {
        let filtered = ruleLines.filter { $0 != rule }
        applyRules(filtered.joined(separator: "\n"), persist: true)
    }

    func clearAll() {
        applyRules("", persist: true)
    }

    func updateRules(_ rawText: String) {
        applyRules(rawText, persist: true)
    }

    private func applyRules(_ raw: String, persist: Bool) {
        var newMusicNames = Set<String>()
        var newSingerNames = Set<String>()
        var newPairs = Set<String>()
        var canonical: [String] = []
        var seenCanonical = Set<String>()

        for rawLine in raw.components(separatedBy: CharacterSet.newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: "@")
            let rawName = parts.first ?? ""
            let rawSinger = parts.count >= 2 ? parts[1] : ""

            let name = Self.normalize(rawName)
            let singer = Self.normalize(rawSinger)

            let canonicalLine: String
            if !name.isEmpty && !singer.isEmpty {
                let pair = "\(name)@\(singer)"
                newPairs.insert(pair)
                canonicalLine = pair
            } else if !name.isEmpty {
                newMusicNames.insert(name)
                canonicalLine = name
            } else if !singer.isEmpty {
                newSingerNames.insert(singer)
                canonicalLine = "@\(singer)"
            } else {
                continue
            }

            if seenCanonical.insert(canonicalLine).inserted {
                canonical.append(canonicalLine)
            }
        }

        self.musicNames = newMusicNames
        self.singerNames = newSingerNames
        self.exactPairs = newPairs
        self.rulesText = canonical.joined(separator: "\n")

        if persist {
            PersistenceStore.shared.saveDislikeRules(self.rulesText)
        }
    }
}
