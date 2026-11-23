import Foundation

/// Full `.lxmc` (gzip JSON) & `.json` import/export codec compatible with LX Music Desktop v1 & v2
/// (`src/common/utils/nodejs.ts`, `SettingBackup.vue`, `useShare.ts`).
enum LXMCBackupCodec {

    enum CodecError: LocalizedError {
        case invalidFileFormat
        case unsupportedBackupType(String)

        var errorDescription: String? {
            switch self {
            case .invalidFileFormat: return "无法解析备份文件，请确认是有效的 .lxmc 或 .json 文件"
            case .unsupportedBackupType(let t): return "暂不支持此备份类型: \(t)"
            }
        }
    }

    struct ImportResult: Sendable {
        let type: String
        let playlists: [UserPlaylist]
        let isSinglePlaylist: Bool
    }

    private struct PlayListV2Envelope: Codable {
        var type: String = "playList_v2"
        var data: [UserPlaylist]
    }

    private struct PlayListPartV2Envelope: Codable {
        var type: String = "playListPart_v2"
        var data: UserPlaylist
    }

    // MARK: - Export

    /// Exports all playlists as gzip-compressed `.lxmc` data compatible with LX Music Desktop `playList_v2`.
    static func exportAllPlaylistsLXMC(_ playlists: [UserPlaylist]) throws -> Data {
        let canonical = playlists.map { pl -> UserPlaylist in
            var copy = pl
            if copy.id == BuiltInListID.default { copy.name = "list__name_default" }
            else if copy.id == BuiltInListID.love { copy.name = "list__name_love" }
            return copy
        }
        let envelope = PlayListV2Envelope(data: canonical)
        let json = try JSONEncoder().encode(envelope)
        return try CryptoUtils.gzipCompress(json)
    }

    /// Exports a single playlist as `.lxmc` (`playListPart_v2`).
    static func exportSinglePlaylistLXMC(_ playlist: UserPlaylist) throws -> Data {
        let envelope = PlayListPartV2Envelope(data: playlist)
        let json = try JSONEncoder().encode(envelope)
        return try CryptoUtils.gzipCompress(json)
    }

    /// Exports playlist songs as UTF-8 BOM text matching `worker/main/list.ts` (`name  singer  album`).
    static func exportPlaylistText(_ playlist: UserPlaylist) -> Data {
        let bom = "\u{FEFF}"
        let lines = playlist.list.map { "\($0.name)  \($0.singer)  \($0.meta.albumName)" }
        return Data((bom + lines.joined(separator: "\n")).utf8)
    }

    /// Exports playlist songs as UTF-8 BOM CSV (`name,singer,album`).
    static func exportPlaylistCSV(_ playlist: UserPlaylist) -> Data {
        func escape(_ s: String) -> String {
            let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
            return escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") ? "\"\(escaped)\"" : escaped
        }
        let bom = "\u{FEFF}"
        let header = "歌曲名,歌手,专辑名"
        let rows = playlist.list.map { "\(escape($0.name)),\(escape($0.singer)),\(escape($0.meta.albumName))" }
        return Data((bom + ([header] + rows).joined(separator: "\n")).utf8)
    }

    // MARK: - Import (supports `.lxmc` gzip & `.json` plain, v2 & legacy v1, double-stringified quirk)

    static func importBackupData(_ rawData: Data) throws -> ImportResult {
        let jsonData: Data
        if rawData.count >= 2 && rawData[0] == 0x1F && rawData[1] == 0x8B {
            jsonData = try CryptoUtils.gunzipDecompress(rawData)
        } else if let gunzipped = try? CryptoUtils.gunzipDecompress(rawData), !gunzipped.isEmpty,
                  gunzipped.first == UInt8(ascii: "{") || gunzipped.first == UInt8(ascii: "\"") {
            jsonData = gunzipped
        } else {
            jsonData = rawData
        }

        // Unwrap potential v1.14.0 double-JSON-stringified payload
        var parsedObj = try JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed])
        if let str = parsedObj as? String, let innerData = str.data(using: .utf8) {
            parsedObj = try JSONSerialization.jsonObject(with: innerData, options: [.fragmentsAllowed])
        }

        guard let root = parsedObj as? [String: Any],
              let type = root["type"] as? String else {
            throw CodecError.invalidFileFormat
        }

        let decoder = JSONDecoder()

        switch type {
        case "playList_v2":
            let normalizedData = try JSONSerialization.data(withJSONObject: root["data"] ?? [])
            let lists = try decoder.decode([UserPlaylist].self, from: normalizedData)
            return ImportResult(type: type, playlists: sanitizePlaylists(lists), isSinglePlaylist: false)

        case "playListPart_v2":
            let normalizedData = try JSONSerialization.data(withJSONObject: root["data"] ?? [:])
            let list = try decoder.decode(UserPlaylist.self, from: normalizedData)
            return ImportResult(type: type, playlists: sanitizePlaylists([list]), isSinglePlaylist: true)

        case "allData_v2":
            let normalizedData = try JSONSerialization.data(withJSONObject: root["playList"] ?? [])
            let lists = try decoder.decode([UserPlaylist].self, from: normalizedData)
            return ImportResult(type: type, playlists: sanitizePlaylists(lists), isSinglePlaylist: false)

        case "playList":
            let rawLists = (root["data"] as? [[String: Any]]) ?? []
            return ImportResult(type: type, playlists: parseLegacyPlaylists(rawLists), isSinglePlaylist: false)

        case "playListPart":
            if let rawList = root["data"] as? [String: Any] {
                return ImportResult(type: type, playlists: parseLegacyPlaylists([rawList]), isSinglePlaylist: true)
            }
            throw CodecError.invalidFileFormat

        case "allData":
            if let rawLists = root["playList"] as? [[String: Any]] {
                return ImportResult(type: type, playlists: parseLegacyPlaylists(rawLists), isSinglePlaylist: false)
            } else if let defObj = root["defaultList"] as? [String: Any],
                      let rawSongs = defObj["list"] as? [[String: Any]] {
                let songs = rawSongs.compactMap(MusicInfo.fromLegacyDictionary)
                return ImportResult(type: type, playlists: [UserPlaylist(id: BuiltInListID.default, name: "list__name_default", list: songs)], isSinglePlaylist: true)
            }
            throw CodecError.invalidFileFormat

        case "defautlList": // exact typo preserved from LX Music Desktop v1!
            let dataObj = (root["data"] as? [String: Any]) ?? [:]
            let rawSongs = (dataObj["list"] as? [[String: Any]]) ?? []
            let songs = rawSongs.compactMap(MusicInfo.fromLegacyDictionary)
            return ImportResult(type: type, playlists: [UserPlaylist(id: BuiltInListID.default, name: "list__name_default", list: songs)], isSinglePlaylist: true)

        default:
            throw CodecError.unsupportedBackupType(type)
        }
    }

    private static func parseLegacyPlaylists(_ rawLists: [[String: Any]]) -> [UserPlaylist] {
        rawLists.compactMap { dict in
            let id = FormatUtils.stringValue(dict["id"])
            guard !id.isEmpty else { return nil }
            let name = FormatUtils.stringValue(dict["name"])
            let src = (dict["source"] as? String).flatMap(MusicSource.init(rawValue:))
            let srcListId = dict["sourceListId"] as? String
            let rawSongs = (dict["list"] as? [[String: Any]]) ?? []
            let songs = rawSongs.compactMap(MusicInfo.fromLegacyDictionary)
            return UserPlaylist(id: id, name: name, source: src, sourceListId: srcListId, list: deduplicateSongs(songs))
        }
    }

    private static func sanitizePlaylists(_ playlists: [UserPlaylist]) -> [UserPlaylist] {
        playlists.map { pl in
            var copy = pl
            copy.list = deduplicateSongs(pl.list)
            return copy
        }
    }

    static func deduplicateSongs(_ list: [MusicInfo]) -> [MusicInfo] {
        var seen = Set<String>()
        return list.filter { !$0.id.isEmpty && !$0.name.isEmpty && seen.insert($0.id).inserted }
    }
}
