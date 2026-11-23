import Foundation

/// Exact 1:1 port of `findMusic` cross-source matching (`src/renderer/utils/musicSdk/index.js` + `versionChars.ts`)
/// and online resolution logic (`src/renderer/core/music/online.ts` + `utils.ts`).
enum MusicMatcher {

    /// All 91 version-sensitive keywords from `src/renderer/utils/musicSdk/versionChars.ts`.
    /// Prevents accidentally matching an instrumental/live/remix/cover/demo track to a studio original.
    static let versionChars: [String] = [
        // Instrumental
        "instrumental", "inst", "karaoke", "backing track", "minus one", "minus vocal",
        "no vocal", "off vocal", "vocal removed", "伴奏", "伴唱", "卡拉ok", "纯音乐",
        "无人声", "去人声", "消音", "オフボーカル", "インスト", "반주", "노래방",
        // Live
        "live", "concert", "tour", "festival", "stage", "session", "现场", "演唱会",
        "巡演", "音乐会", "ライブ", "공연", "라이브",
        // Cover
        "cover", "tribute", "rendition", "remake", "翻唱", "致敬", "改编", "カバー", "커버",
        // Remix
        "remix", "mix", "club", "dance", "extended", "house", "edm", "dj", "dub", "trap",
        "混音", "重混", "电音", "リミックス", "리믹스",
        // Acoustic
        "acoustic", "unplugged", "stripped", "原声", "不插电", "アコースティック", "어쿠스틱",
        // Demo
        "demo", "小样", "试听", "デモ", "데모",
        // Speed
        "slowed", "slowed reverb", "sped up", "speed up", "nightcore", "慢速", "加速", "变速", "ナイトコア",
        // Special instrumental
        "piano", "guitar", "orchestra", "symphony", "violin", "钢琴", "吉他", "管弦乐",
        "小提琴", "ピアノ", "ギター", "피아노", "기타",
    ]

    private static let filterPattern = #"[\s'.,，&"、()（）`~\-<>|/\]\[!！]"#

    static func filterStr(_ str: String) -> String {
        RegexHelper.replace(filterPattern, in: str, with: "")
    }

    static func sortSinger(_ singer: String) -> String {
        let separators = CharacterSet(charactersIn: "、&;；/,，|")
        let parts = singer.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count > 1 else { return singer }
        return parts.sorted { $0.localizedCompare($1) == .orderedAscending }.joined(separator: "、")
    }

    /// Searches all other online sources in parallel and returns ranked cross-source equivalents (`findMusic`).
    static func findOtherSourceMatches(for target: MusicInfo, limit: Int = 25) async -> [MusicInfo] {
        let query = "\(target.name.trimmingCharacters(in: .whitespaces)) \(target.singer)".trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }

        let otherSDKs = MusicSDKRegistry.shared.allOnlineSDKs.filter { $0.source != target.source }
        let searchResults: [[MusicInfo]] = await withTaskGroup(of: (Int, [MusicInfo]).self) { group in
            for (idx, sdk) in otherSDKs.enumerated() {
                group.addTask {
                    let list = (try? await sdk.searchMusic(query: query, page: 1, limit: limit).list) ?? []
                    return (idx, list)
                }
            }
            var ordered = Array(repeating: [MusicInfo](), count: otherSDKs.count)
            for await (idx, list) in group {
                ordered[idx] = list
            }
            return ordered
        }

        return rankCandidates(target: target, candidateLists: searchResults)
    }

    /// Pure deterministic ranking algorithm matching `musicSdk/index.js:findMusic` (3 passes + 9 priority tiers).
    static func rankCandidates(target: MusicInfo, candidateLists: [[MusicInfo]]) -> [MusicInfo] {
        let fMusicName = filterStr(target.name).lowercased()
        let fSinger = filterStr(sortSinger(target.singer)).lowercased()
        let fAlbumName = filterStr(target.meta.albumName).lowercased()
        let fInterval = FormatUtils.parseIntervalSeconds(target.interval)

        func isEqualsInterval(_ intv: Int) -> Bool {
            let a = fInterval != 0 ? fInterval : intv
            let b = intv != 0 ? intv : fInterval
            return abs(a - b) <= 5
        }

        func isEqualsVersion(_ name: String) -> Bool {
            versionChars.allSatisfy { name.contains($0) == fMusicName.contains($0) }
        }

        func isIncludesName(_ name: String) -> Bool {
            (fMusicName.contains(name) || name.contains(fMusicName)) && isEqualsVersion(name)
        }

        func isIncludesSinger(_ singer: String) -> Bool {
            if fSinger.isEmpty { return true }
            return fSinger.contains(singer) || singer.contains(fSinger)
        }

        func isEqualsAlbum(_ album: String) -> Bool {
            if fAlbumName.isEmpty { return true }
            return fAlbumName == album
        }

        struct Candidate {
            let music: MusicInfo
            let fName: String
            let fSinger: String
            let fAlbum: String
            let fIntv: Int
        }

        var winners: [Candidate] = []
        for list in candidateLists {
            let valid: [Candidate] = list.compactMap { item in
                let c = Candidate(
                    music: item,
                    fName: filterStr(item.name.trimmingCharacters(in: .whitespaces)).lowercased(),
                    fSinger: filterStr(sortSinger(item.singer.trimmingCharacters(in: .whitespaces))).lowercased(),
                    fAlbum: filterStr(item.meta.albumName).lowercased(),
                    fIntv: FormatUtils.parseIntervalSeconds(item.interval)
                )
                return isEqualsInterval(c.fIntv) ? c : nil
            }

            // Pass 1: exact name + includes singer
            if let hit = valid.first(where: { $0.fName == fMusicName && isIncludesSinger($0.fSinger) }) {
                winners.append(hit)
                continue
            }
            // Pass 2: exact singer + includes name (with version guard)
            if let hit = valid.first(where: { $0.fSinger == fSinger && isIncludesName($0.fName) }) {
                winners.append(hit)
                continue
            }
            // Pass 3: exact album + includes singer + includes name
            if let hit = valid.first(where: { isEqualsAlbum($0.fAlbum) && isIncludesSinger($0.fSinger) && isIncludesName($0.fName) }) {
                winners.append(hit)
            }
        }

        // 9-tier priority sort (exact order from `musicSdk/index.js`)
        let targetInterval = target.interval
        var remaining = winners
        var ranked: [MusicInfo] = []

        func extract(_ predicate: (Candidate) -> Bool) {
            var nextRemaining: [Candidate] = []
            for c in remaining {
                if predicate(c) {
                    ranked.append(c.music)
                } else {
                    nextRemaining.append(c)
                }
            }
            remaining = nextRemaining
        }

        extract { $0.fSinger == fSinger && $0.fName == fMusicName && $0.music.interval == targetInterval }
        extract { $0.fName == fMusicName && $0.fSinger == fSinger && $0.fAlbum == fAlbumName }
        extract { $0.fSinger == fSinger && $0.fName == fMusicName }
        extract { $0.fName == fMusicName && $0.music.interval == targetInterval }
        extract { $0.fSinger == fSinger && $0.music.interval == targetInterval }
        extract { $0.music.interval == targetInterval }
        extract { $0.fName == fMusicName }
        extract { $0.fSinger == fSinger }
        extract { $0.fAlbum == fAlbumName }
        ranked.append(contentsOf: remaining.map(\.music))

        return ranked
    }

    /// Exact port of `getPlayQuality` (`core/music/utils.ts`).
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
