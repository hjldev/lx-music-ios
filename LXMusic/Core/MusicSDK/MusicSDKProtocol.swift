import Foundation

enum MusicSDKError: LocalizedError {
    case unsupportedSource(MusicSource)
    case httpStatus(Int, String)
    case apiError(String)
    case parseError(String)
    case lyricNotFound
    case picNotFound
    case noActiveCustomSource
    case customSourceNotSupported(MusicSource)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource(let s): return "暂不支持音源: \(s.displayName)"
        case .httpStatus(let code, let msg): return "HTTP \(code): \(msg)"
        case .apiError(let msg): return msg
        case .parseError(let msg): return "数据解析失败: \(msg)"
        case .lyricNotFound: return "未找到歌词"
        case .picNotFound: return "未找到封面图片"
        case .noActiveCustomSource: return "未启用自定义音源脚本，请先在「设置 -> 自定义音源」中导入并启用"
        case .customSourceNotSupported(let s): return "当前自定义音源不支持 \(s.displayName)"
        }
    }
}

/// Unified interface for online Music SDKs (Kuwo).
protocol MusicSDK: Sendable {
    var source: MusicSource { get }
    var songListSortOptions: [SongListSortOption] { get }
    var leaderboardBoards: [LeaderboardBoard] { get }

    func searchMusic(query: String, page: Int, limit: Int) async throws -> MusicSearchPage
    func searchSongList(query: String, page: Int, limit: Int) async throws -> SongListSearchPage
    func getHotSearch() async throws -> [String]
    func getTipSearch(query: String) async throws -> [String]

    func getSongListTags() async throws -> SongListTagsResult
    func getSongList(sortId: String, tagId: String?, page: Int) async throws -> SongListSearchPage
    func getSongListDetail(idOrUrl: String, page: Int) async throws -> SongListDetailPage

    func getLeaderboardTracks(bangId: String, page: Int) async throws -> LeaderboardPage

    func getLyric(musicInfo: MusicInfo) async throws -> LyricInfo
    func getPic(musicInfo: MusicInfo) async throws -> String
}

/// Central registry exposing the built-in Kuwo Music SDK.
final class MusicSDKRegistry: @unchecked Sendable {
    static let shared = MusicSDKRegistry()

    let kw = KWMusicSDK()

    func sdk(for source: MusicSource) -> MusicSDK? {
        switch source {
        case .kw: return kw
        case .kg, .tx, .wy, .mg, .local: return nil
        }
    }

    var allOnlineSDKs: [MusicSDK] {
        [kw]
    }
}

/// Regex convenience helpers used across SDK parsers.
enum RegexHelper {
    static func firstMatch(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        for i in 0..<match.numberOfRanges {
            let r = match.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return groups
    }

    static func allMatches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { i in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    static func replace(_ pattern: String, in text: String, with template: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    static func test(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> Bool {
        firstMatch(pattern, in: text, options: options) != nil
    }
}
