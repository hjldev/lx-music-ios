import Foundation

/// Represents one available quality entry for a track (matching `LX.Music.MusicQualityType` & `MusicQualityTypeKg`).
struct MusicQualityItem: Codable, Hashable, Sendable {
    var type: AudioQuality
    var size: String?
    var hash: String?

    init(type: AudioQuality, size: String? = nil, hash: String? = nil) {
        self.type = type
        self.size = size
        self.hash = hash
    }

    enum CodingKeys: String, CodingKey {
        case type, size, hash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        self.type = AudioQuality.fromRawMigrated(rawType) ?? .k128
        self.size = try container.decodeIfPresent(String.self, forKey: .size)
        self.hash = try container.decodeIfPresent(String.self, forKey: .hash)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type.rawValue, forKey: .type)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(hash, forKey: .hash)
    }
}

/// Quality metadata value for `_qualitys` map.
struct MusicQualityMeta: Codable, Hashable, Sendable {
    var size: String?
    var hash: String?

    init(size: String? = nil, hash: String? = nil) {
        self.size = size
        self.hash = hash
    }
}

/// Source-specific track metadata matching LX Music Desktop v2 (`LX.Music.MusicInfoMeta_*`).
struct MusicMeta: Codable, Hashable, Sendable {
    var songId: String
    var albumName: String
    var picUrl: String?
    var albumId: String?
    var qualitys: [MusicQualityItem]
    var _qualitys: [String: MusicQualityMeta]

    // KG specific
    var hash: String?
    var albumAudioId: String?

    // TX specific
    var strMediaMid: String?
    var txSongId: String?
    var albumMid: String?

    // MG specific
    var copyrightId: String?
    var lrcUrl: String?
    var mrcUrl: String?
    var trcUrl: String?

    // Local specific
    var filePath: String?
    var ext: String?

    init(
        songId: String,
        albumName: String = "",
        picUrl: String? = nil,
        albumId: String? = nil,
        qualitys: [MusicQualityItem] = [],
        _qualitys: [String: MusicQualityMeta]? = nil,
        hash: String? = nil,
        albumAudioId: String? = nil,
        strMediaMid: String? = nil,
        txSongId: String? = nil,
        albumMid: String? = nil,
        copyrightId: String? = nil,
        lrcUrl: String? = nil,
        mrcUrl: String? = nil,
        trcUrl: String? = nil,
        filePath: String? = nil,
        ext: String? = nil
    ) {
        self.songId = songId
        self.albumName = albumName
        self.picUrl = picUrl
        self.albumId = albumId
        self.qualitys = qualitys
        if let provided = _qualitys {
            self._qualitys = provided
        } else {
            var dict: [String: MusicQualityMeta] = [:]
            for item in qualitys {
                dict[item.type.rawValue] = MusicQualityMeta(size: item.size, hash: item.hash)
            }
            self._qualitys = dict
        }
        self.hash = hash
        self.albumAudioId = albumAudioId
        self.strMediaMid = strMediaMid
        self.txSongId = txSongId
        self.albumMid = albumMid
        self.copyrightId = copyrightId
        self.lrcUrl = lrcUrl
        self.mrcUrl = mrcUrl
        self.trcUrl = trcUrl
        self.filePath = filePath
        self.ext = ext
    }

    enum CodingKeys: String, CodingKey {
        case songId, albumName, picUrl, albumId, qualitys, _qualitys
        case hash, albumAudioId
        case strMediaMid, txSongId = "id", albumMid
        case copyrightId, lrcUrl, mrcUrl, trcUrl
        case filePath, ext
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.songId = c.decodeFlexibleString(forKey: .songId) ?? ""
        self.albumName = (try? c.decodeIfPresent(String.self, forKey: .albumName)) ?? ""
        self.picUrl = try? c.decodeIfPresent(String.self, forKey: .picUrl)
        self.albumId = c.decodeFlexibleString(forKey: .albumId)
        self.qualitys = (try? c.decodeIfPresent([MusicQualityItem].self, forKey: .qualitys)) ?? []

        if let rawDict = try? c.decodeIfPresent([String: MusicQualityMeta].self, forKey: ._qualitys) {
            var migrated: [String: MusicQualityMeta] = [:]
            for (k, v) in rawDict {
                let normalizedKey = (k == "flac32bit") ? "flac24bit" : k
                migrated[normalizedKey] = v
            }
            self._qualitys = migrated
        } else {
            var dict: [String: MusicQualityMeta] = [:]
            for item in self.qualitys {
                dict[item.type.rawValue] = MusicQualityMeta(size: item.size, hash: item.hash)
            }
            self._qualitys = dict
        }

        self.hash = c.decodeFlexibleString(forKey: .hash)
        self.albumAudioId = c.decodeFlexibleString(forKey: .albumAudioId)
        self.strMediaMid = c.decodeFlexibleString(forKey: .strMediaMid)
        self.txSongId = c.decodeFlexibleString(forKey: .txSongId)
        self.albumMid = c.decodeFlexibleString(forKey: .albumMid)
        self.copyrightId = c.decodeFlexibleString(forKey: .copyrightId)
        self.lrcUrl = try? c.decodeIfPresent(String.self, forKey: .lrcUrl)
        self.mrcUrl = try? c.decodeIfPresent(String.self, forKey: .mrcUrl)
        self.trcUrl = try? c.decodeIfPresent(String.self, forKey: .trcUrl)
        self.filePath = try? c.decodeIfPresent(String.self, forKey: .filePath)
        self.ext = try? c.decodeIfPresent(String.self, forKey: .ext)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(songId, forKey: .songId)
        try c.encode(albumName, forKey: .albumName)
        try c.encodeIfPresent(picUrl, forKey: .picUrl)
        try c.encodeIfPresent(albumId, forKey: .albumId)
        try c.encode(qualitys, forKey: .qualitys)
        try c.encode(_qualitys, forKey: ._qualitys)
        try c.encodeIfPresent(hash, forKey: .hash)
        try c.encodeIfPresent(albumAudioId, forKey: .albumAudioId)
        try c.encodeIfPresent(strMediaMid, forKey: .strMediaMid)
        try c.encodeIfPresent(txSongId, forKey: .txSongId)
        try c.encodeIfPresent(albumMid, forKey: .albumMid)
        try c.encodeIfPresent(copyrightId, forKey: .copyrightId)
        try c.encodeIfPresent(lrcUrl, forKey: .lrcUrl)
        try c.encodeIfPresent(mrcUrl, forKey: .mrcUrl)
        try c.encodeIfPresent(trcUrl, forKey: .trcUrl)
        try c.encodeIfPresent(filePath, forKey: .filePath)
        try c.encodeIfPresent(ext, forKey: .ext)
    }
}

/// Core music track model matching LX Music Desktop v2 (`LX.Music.MusicInfo`).
struct MusicInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var singer: String
    var source: MusicSource
    var interval: String?
    var meta: MusicMeta

    init(
        id: String,
        name: String,
        singer: String,
        source: MusicSource,
        interval: String? = nil,
        meta: MusicMeta
    ) {
        self.id = id
        self.name = name
        self.singer = singer
        self.source = source
        self.interval = interval
        self.meta = meta
    }

    /// Highest available quality badge for compact display in track rows.
    var highestQuality: AudioQuality? {
        meta.qualitys.max(by: { $0.type.sortRank < $1.type.sortRank })?.type
    }

    func hasQuality(_ quality: AudioQuality) -> Bool {
        meta._qualitys[quality.rawValue] != nil
    }

    /// Converts v2 `MusicInfo` into LX Music Desktop's legacy `OldMusicInfo` JS dictionary
    /// expected by custom source (`userApi`) scripts in `lx.on('request', ({ info: { musicInfo } }))`.
    func toLegacyDictionary() -> [String: Any] {
        var types: [[String: Any]] = []
        var _types: [String: Any] = [:]
        for item in meta.qualitys {
            var obj: [String: Any] = ["type": item.type.rawValue]
            if let size = item.size { obj["size"] = size } else { obj["size"] = NSNull() }
            if let hash = item.hash { obj["hash"] = hash }
            types.append(obj)

            var mapObj: [String: Any] = [:]
            if let size = item.size { mapObj["size"] = size } else { mapObj["size"] = NSNull() }
            if let hash = item.hash { mapObj["hash"] = hash }
            _types[item.type.rawValue] = mapObj
        }

        var dict: [String: Any] = [
            "name": name,
            "singer": singer,
            "source": source.rawValue,
            "songmid": meta.songId,
            "albumName": meta.albumName,
            "albumId": meta.albumId ?? "",
            "interval": interval ?? "",
            "img": meta.picUrl ?? "",
            "lrc": NSNull(),
            "types": types,
            "_types": _types,
            "typeUrl": [String: Any](),
        ]

        // Source-specific fields matching `src/common/utils/tools.ts:toOldMusicInfo`
        switch source {
        case .kg:
            dict["hash"] = meta.hash ?? ""
            if let albumAudioId = meta.albumAudioId {
                dict["albumAudioId"] = albumAudioId
            }
        case .tx:
            dict["strMediaMid"] = meta.strMediaMid ?? ""
            dict["albumMid"] = meta.albumMid ?? ""
            if let txSongId = meta.txSongId {
                dict["songId"] = txSongId
            }
        case .mg:
            dict["copyrightId"] = meta.copyrightId ?? ""
            if let lrcUrl = meta.lrcUrl { dict["lrcUrl"] = lrcUrl }
            if let mrcUrl = meta.mrcUrl { dict["mrcUrl"] = mrcUrl }
            if let trcUrl = meta.trcUrl { dict["trcUrl"] = trcUrl }
        case .local:
            dict["filePath"] = meta.filePath ?? ""
            dict["ext"] = meta.ext ?? ""
        case .kw, .wy:
            break
        }

        return dict
    }

    /// Builds a v2 `MusicInfo` from a legacy v1 JSON dictionary (used when importing v1 `.lxmc` backups).
    static func fromLegacyDictionary(_ dict: [String: Any]) -> MusicInfo? {
        guard let sourceStr = dict["source"] as? String,
              let source = MusicSource(rawValue: sourceStr),
              let name = dict["name"] as? String, !name.isEmpty else {
            return nil
        }

        let singer = (dict["singer"] as? String) ?? ""
        let songmid: String
        if let s = dict["songmid"] as? String {
            songmid = s
        } else if let n = dict["songmid"] as? Int64 {
            songmid = String(n)
        } else if let n = dict["songmid"] as? Int {
            songmid = String(n)
        } else {
            return nil
        }

        let albumName = (dict["albumName"] as? String) ?? ""
        let albumId: String? = (dict["albumId"] as? String) ?? (dict["albumId"] as? Int).map(String.init)
        let img = dict["img"] as? String
        let interval = dict["interval"] as? String

        var qualitys: [MusicQualityItem] = []
        var _qualitys: [String: MusicQualityMeta] = [:]
        if let rawTypes = dict["types"] as? [[String: Any]] {
            for t in rawTypes {
                if let typeStr = t["type"] as? String, let q = AudioQuality.fromRawMigrated(typeStr) {
                    let size = t["size"] as? String
                    let hash = t["hash"] as? String
                    qualitys.append(MusicQualityItem(type: q, size: size, hash: hash))
                    _qualitys[q.rawValue] = MusicQualityMeta(size: size, hash: hash)
                }
            }
        }

        let hash = dict["hash"] as? String
        let albumAudioId = (dict["albumAudioId"] as? String) ?? (dict["albumAudioId"] as? Int64).map(String.init) ?? (dict["albumAudioId"] as? Int).map(String.init)
        let strMediaMid = dict["strMediaMid"] as? String
        let txSongId = (dict["songId"] as? String) ?? (dict["songId"] as? Int64).map(String.init) ?? (dict["songId"] as? Int).map(String.init)
        let albumMid = dict["albumMid"] as? String
        let copyrightId = (dict["copyrightId"] as? String) ?? (dict["copyrightId"] as? Int64).map(String.init)
        let lrcUrl = dict["lrcUrl"] as? String
        let mrcUrl = dict["mrcUrl"] as? String
        let trcUrl = dict["trcUrl"] as? String

        let id = (source == .kg && hash != nil) ? "\(songmid)_\(hash!)" : "\(source.rawValue)_\(songmid)"
        let meta = MusicMeta(
            songId: songmid,
            albumName: albumName,
            picUrl: img,
            albumId: albumId,
            qualitys: qualitys,
            _qualitys: _qualitys,
            hash: hash,
            albumAudioId: albumAudioId,
            strMediaMid: strMediaMid,
            txSongId: txSongId,
            albumMid: albumMid,
            copyrightId: copyrightId,
            lrcUrl: lrcUrl,
            mrcUrl: mrcUrl,
            trcUrl: trcUrl
        )

        return MusicInfo(
            id: id,
            name: name,
            singer: singer,
            source: source,
            interval: interval,
            meta: meta
        )
    }
}

extension KeyedDecodingContainer {
    /// Decodes either a String or an Int/Int64 as String (handles JS `string | number` union types).
    func decodeFlexibleString(forKey key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return s
        }
        if let i = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(i)
        }
        if let d = try? decodeIfPresent(Double.self, forKey: key) {
            return String(Int64(d))
        }
        return nil
    }
}
