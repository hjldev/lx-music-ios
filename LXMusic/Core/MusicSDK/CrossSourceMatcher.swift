import Foundation

/// Cross-platform music search and candidate matcher faithfully porting LX Music Desktop:
/// - `src/renderer/utils/musicSdk/index.js` (`searchMusic`, `findMusic`)
/// - `src/renderer/utils/musicSdk/versionChars.ts`
/// - `src/renderer/utils/musicSdk/kg/musicSearch.js`
/// - `src/renderer/utils/musicSdk/tx/musicSearch.js` + `tx/utils/crypto.js` + `tx/utils/index.js`
/// - `src/renderer/utils/musicSdk/wy/musicSearch.js` + `wy/utils/crypto.js` + `wy/utils/index.js`
/// - `src/renderer/utils/musicSdk/mg/musicSearch.js`
final class CrossSourceMatcher: @unchecked Sendable {
    static let shared = CrossSourceMatcher()

    typealias PlatformSearchHandler = @Sendable (MusicSource, String, Int) async throws -> [MusicInfo]

    private let searchHandler: PlatformSearchHandler?
    private let cacheLock = NSLock()
    private var matchCache: [String: [MusicInfo]] = [:]

    init(searchHandler: PlatformSearchHandler? = nil) {
        self.searchHandler = searchHandler
    }

    func clearCache() {
        cacheLock.lock()
        matchCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Public Cross-Source Matching (`findMusic` + `getOtherSource`)

    /// Searches alternate online platforms (`kg`, `tx`, `wy`, `mg`, `kw` excluding `track.source`) in parallel
    /// and returns the best matched track per platform sorted by match precision.
    func findMusic(
        for track: MusicInfo,
        in candidateSources: [MusicSource]? = nil,
        limit: Int = 25,
        ignoreCache: Bool = false
    ) async -> [MusicInfo] {
        let targets = (candidateSources ?? MusicSource.onlineSources)
            .filter { $0 != track.source && $0 != .local }
        guard !targets.isEmpty else { return [] }

        let cacheKey = "\(track.id)|\(targets.map(\.rawValue).joined(separator: ","))"
        if !ignoreCache {
            cacheLock.lock()
            let cached = matchCache[cacheKey]
            cacheLock.unlock()
            if let cached { return cached }
        }

        let query = "\(track.name.trimmingCharacters(in: .whitespacesAndNewlines)) \(track.singer.trimmingCharacters(in: .whitespacesAndNewlines))"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        // Run searches concurrently across all target platforms, preserving source order
        var resultsBySource: [MusicSource: [MusicInfo]] = [:]
        await withTaskGroup(of: (MusicSource, [MusicInfo]).self) { group in
            for source in targets {
                group.addTask { [self] in
                    let list = (try? await self.searchPlatform(source, query: query, limit: limit)) ?? []
                    return (source, list)
                }
            }
            for await (source, list) in group {
                if !list.isEmpty {
                    resultsBySource[source] = list
                }
            }
        }

        let orderedLists = targets.compactMap { resultsBySource[$0] }
        let matched = Self.matchAndRank(target: track, sourceLists: orderedLists)

        if !matched.isEmpty {
            cacheLock.lock()
            if matchCache.count > 20 {
                matchCache.removeAll()
            }
            matchCache[cacheKey] = matched
            cacheLock.unlock()
        }

        return matched
    }

    /// Dispatches a search query to a specific platform's music search API.
    func searchPlatform(_ source: MusicSource, query: String, limit: Int = 25) async throws -> [MusicInfo] {
        if let custom = searchHandler {
            return try await custom(source, query, limit)
        }
        switch source {
        case .kw:
            let page = try await MusicSDKRegistry.shared.kw.searchMusic(query: query, page: 1, limit: limit)
            return page.list
        case .kg:
            return try await searchKG(query: query, page: 1, limit: limit)
        case .tx:
            return try await searchTX(query: query, page: 1, limit: limit)
        case .wy:
            return try await searchWY(query: query, page: 1, limit: limit)
        case .mg:
            return try await searchMG(query: query, page: 1, limit: limit)
        case .local:
            return []
        }
    }

    // MARK: - Platform 1: Kugou (`kg/musicSearch.js`)

    private func searchKG(query: String, page: Int, limit: Int) async throws -> [MusicInfo] {
        try await HTTPClient.withRetry(maxAttempts: 2) {
            let encoded = FormatUtils.urlEncodeComponent(query)
            let url = "http://songsearch.kugou.com/song_search_v2?platform=AndroidFilter&iscorrection=1&keyword=\(encoded)&hifiquality=0&pagesize=\(limit)&PrivilegeFilter=0&page=\(page)"
            let resp = try await HTTPClient.shared.get(url, timeout: 6.0)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["error_code"]) == 0,
                  let data = body["data"] as? [String: Any],
                  let lists = data["lists"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("KG search failed")
            }

            var seen = Set<String>()
            var output: [MusicInfo] = []

            func appendItem(_ raw: [String: Any]) {
                let songmid = FormatUtils.stringValue(raw["Audioid"])
                let fileHash = FormatUtils.stringValue(raw["FileHash"])
                guard !songmid.isEmpty, !fileHash.isEmpty else { return }
                let dedupKey = "\(songmid)\(fileHash)"
                guard seen.insert(dedupKey).inserted else { return }

                var types: [MusicQualityItem] = []
                var map: [String: MusicQualityMeta] = [:]

                let fileSize = FormatUtils.int64Value(raw["FileSize"])
                if fileSize != 0 {
                    let size = FormatUtils.sizeFormate(fileSize)
                    types.append(MusicQualityItem(type: .k128, size: size, hash: fileHash))
                    map[AudioQuality.k128.rawValue] = MusicQualityMeta(size: size, hash: fileHash)
                }
                let hqSize = FormatUtils.int64Value(raw["HQFileSize"])
                let hqHash = FormatUtils.stringValue(raw["HQFileHash"])
                if hqSize != 0 && !hqHash.isEmpty {
                    let size = FormatUtils.sizeFormate(hqSize)
                    types.append(MusicQualityItem(type: .k320, size: size, hash: hqHash))
                    map[AudioQuality.k320.rawValue] = MusicQualityMeta(size: size, hash: hqHash)
                }
                let sqSize = FormatUtils.int64Value(raw["SQFileSize"])
                let sqHash = FormatUtils.stringValue(raw["SQFileHash"])
                if sqSize != 0 && !sqHash.isEmpty {
                    let size = FormatUtils.sizeFormate(sqSize)
                    types.append(MusicQualityItem(type: .flac, size: size, hash: sqHash))
                    map[AudioQuality.flac.rawValue] = MusicQualityMeta(size: size, hash: sqHash)
                }
                let resSize = FormatUtils.int64Value(raw["ResFileSize"])
                let resHash = FormatUtils.stringValue(raw["ResFileHash"])
                if resSize != 0 && !resHash.isEmpty {
                    let size = FormatUtils.sizeFormate(resSize)
                    types.append(MusicQualityItem(type: .flac24bit, size: size, hash: resHash))
                    map[AudioQuality.flac24bit.rawValue] = MusicQualityMeta(size: size, hash: resHash)
                }

                let oriName = FormatUtils.stringValue(raw["OriSongName"])
                let suffix = FormatUtils.stringValue(raw["Suffix"])
                let fullName = suffix.isEmpty ? oriName : "\(oriName) \(suffix)"
                let singers = raw["Singers"] as? [[String: Any]]
                let singerName: String
                if let singers, !singers.isEmpty {
                    singerName = FormatUtils.formatSingerName(singers, nameKey: "name")
                } else {
                    singerName = FormatUtils.decodeName(raw["SingerName"] as? String)
                }

                let duration = FormatUtils.intValue(raw["Duration"])
                let albumAudioId = FormatUtils.stringValue(raw["MixSongID"])

                output.append(MusicInfo(
                    id: "\(songmid)_\(fileHash)",
                    name: FormatUtils.decodeName(fullName),
                    singer: singerName,
                    source: .kg,
                    interval: duration > 0 ? FormatUtils.formatPlayTime(duration) : nil,
                    meta: MusicMeta(
                        songId: songmid,
                        albumName: FormatUtils.decodeName(raw["AlbumName"] as? String),
                        picUrl: nil,
                        albumId: FormatUtils.stringValue(raw["AlbumID"]),
                        qualitys: types,
                        _qualitys: map,
                        hash: fileHash,
                        albumAudioId: albumAudioId.isEmpty ? nil : albumAudioId
                    )
                ))
            }

            for item in lists {
                appendItem(item)
                if let grp = item["Grp"] as? [[String: Any]] {
                    for child in grp {
                        appendItem(child)
                    }
                }
            }
            return output
        }
    }

    // MARK: - Platform 2: QQ Music (`tx/musicSearch.js` + `tx/utils/crypto.js`)

    private static let txPart1Indexes = [23, 14, 6, 36, 16, 40, 7, 19]
    private static let txPart2Indexes = [16, 1, 32, 12, 19, 27, 8, 5]
    private static let txScrambleValues: [UInt8] = [
        89, 39, 179, 150, 218, 82, 58, 252, 177, 52,
        186, 123, 120, 64, 242, 133, 143, 161, 121, 179,
    ]

    /// Exact Swift port of `tx/utils/crypto.js:zzcSign`.
    static func zzcSign(_ text: String) -> String {
        let sha1Data = CryptoUtils.sha1(Data(text.utf8))
        let hashHex = sha1Data.hexLowercased
        let hashChars = Array(hashHex)

        let part1 = String(txPart1Indexes.compactMap { idx in
            idx < hashChars.count ? hashChars[idx] : nil
        })
        let part2 = String(txPart2Indexes.compactMap { idx in
            idx < hashChars.count ? hashChars[idx] : nil
        })

        let sha1Bytes = [UInt8](sha1Data)
        var scrambled = [UInt8]()
        scrambled.reserveCapacity(txScrambleValues.count)
        for i in 0..<min(txScrambleValues.count, sha1Bytes.count) {
            scrambled.append(txScrambleValues[i] ^ sha1Bytes[i])
        }

        let b64Part = Data(scrambled)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "\\", with: "")

        return "zzc\(part1)\(b64Part)\(part2)".lowercased()
    }

    private static func txSearchId() -> String {
        let hex = CryptoUtils.randomBytes(16).hexUppercased
        let rand5 = String(format: "%05d", Int.random(in: 0..<100_000))
        return hex + rand5
    }

    private func searchTX(query: String, page: Int, limit: Int) async throws -> [MusicInfo] {
        try await HTTPClient.withRetry(maxAttempts: 2) {
            let payload: [String: Any] = [
                "comm": [
                    "_channelid": "0",
                    "_os_version": "6.2.9200-2",
                    "ct": "19",
                    "cv": "2151",
                    "guid": "1F70E520B2EAA7D25E11760783C53CA9",
                    "patch": "118",
                    "psrf_access_token_expiresAt": 0,
                    "psrf_qqaccess_token": "",
                    "psrf_qqopenid": "",
                    "psrf_qqunionid": "",
                    "tmeAppID": "qqmusic",
                    "tmeLoginType": 0,
                    "uin": "0",
                    "wid": "7223299733393904640",
                ],
                "music.search.SearchCgiService": [
                    "module": "music.search.SearchCgiService",
                    "method": "DoSearchForQQMusicDesktop",
                    "param": [
                        "grp": 1,
                        "num_per_page": limit,
                        "page_num": page,
                        "query": query,
                        "remoteplace": "txt.newclient.top",
                        "search_type": 0,
                        "searchid": Self.txSearchId(),
                    ],
                ],
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
            guard let jsonStr = String(data: jsonData, encoding: .utf8) else {
                throw MusicSDKError.parseError("TX JSON serialization failed")
            }
            let sign = Self.zzcSign(jsonStr)
            let url = "https://u.y.qq.com/cgi-bin/musics.fcg?sign=\(sign)"
            let resp = try await HTTPClient.shared.request(
                url,
                method: "POST",
                headers: ["User-Agent": "QQMusic 14090508(android 12)"],
                body: .jsonString(jsonStr),
                timeout: 6.0
            )
            let body = try resp.jsonDictionary()
            let reqObj = (body["music.search.SearchCgiService"] as? [String: Any]) ?? (body["req"] as? [String: Any])
            guard let reqObj,
                  FormatUtils.intValue(body["code"]) == 0,
                  FormatUtils.intValue(reqObj["code"]) == 0,
                  let dataObj = reqObj["data"] as? [String: Any],
                  let bodyObj = dataObj["body"] as? [String: Any],
                  let songObj = bodyObj["song"] as? [String: Any],
                  let rawList = songObj["list"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("TX search failed")
            }

            return rawList.compactMap { item -> MusicInfo? in
                guard let file = item["file"] as? [String: Any] else { return nil }
                let mediaMid = FormatUtils.stringValue(file["media_mid"])
                let songmid = FormatUtils.stringValue(item["mid"])
                guard !mediaMid.isEmpty, !songmid.isEmpty else { return nil }

                var types: [MusicQualityItem] = []
                var map: [String: MusicQualityMeta] = [:]

                let size128 = FormatUtils.int64Value(file["size_128mp3"])
                if size128 != 0 {
                    let s = FormatUtils.sizeFormate(size128)
                    types.append(MusicQualityItem(type: .k128, size: s))
                    map[AudioQuality.k128.rawValue] = MusicQualityMeta(size: s)
                }
                let size320 = FormatUtils.int64Value(file["size_320mp3"])
                if size320 != 0 {
                    let s = FormatUtils.sizeFormate(size320)
                    types.append(MusicQualityItem(type: .k320, size: s))
                    map[AudioQuality.k320.rawValue] = MusicQualityMeta(size: s)
                }
                let sizeFlac = FormatUtils.int64Value(file["size_flac"])
                if sizeFlac != 0 {
                    let s = FormatUtils.sizeFormate(sizeFlac)
                    types.append(MusicQualityItem(type: .flac, size: s))
                    map[AudioQuality.flac.rawValue] = MusicQualityMeta(size: s)
                }
                let sizeHires = FormatUtils.int64Value(file["size_hires"])
                if sizeHires != 0 {
                    let s = FormatUtils.sizeFormate(sizeHires)
                    types.append(MusicQualityItem(type: .flac24bit, size: s))
                    map[AudioQuality.flac24bit.rawValue] = MusicQualityMeta(size: s)
                }

                let album = item["album"] as? [String: Any]
                let albumName = FormatUtils.decodeName(album?["name"] as? String)
                let albumMid = FormatUtils.stringValue(album?["mid"])
                let singers = item["singer"] as? [[String: Any]]
                let singerName = FormatUtils.formatSingerName(singers, nameKey: "name")

                let picUrl: String?
                if albumMid.isEmpty || albumMid == "空" {
                    if let firstSingerMid = singers?.first?["mid"] as? String, !firstSingerMid.isEmpty {
                        picUrl = "https://y.gtimg.cn/music/photo_new/T001R500x500M000\(firstSingerMid).jpg"
                    } else {
                        picUrl = nil
                    }
                } else {
                    picUrl = "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(albumMid).jpg"
                }

                let duration = FormatUtils.intValue(item["interval"])
                let txSongId = FormatUtils.stringValue(item["id"])
                let title = FormatUtils.decodeName(item["title"] as? String)

                return MusicInfo(
                    id: "tx_\(songmid)",
                    name: title,
                    singer: singerName,
                    source: .tx,
                    interval: duration > 0 ? FormatUtils.formatPlayTime(duration) : nil,
                    meta: MusicMeta(
                        songId: songmid,
                        albumName: albumName,
                        picUrl: picUrl,
                        albumId: albumMid,
                        qualitys: types,
                        _qualitys: map,
                        strMediaMid: mediaMid,
                        txSongId: txSongId.isEmpty ? nil : txSongId,
                        albumMid: albumMid
                    )
                )
            }
        }
    }

    // MARK: - Platform 3: NetEase Cloud Music (`wy/musicSearch.js` + `wy/utils/crypto.js`)

    private static let wyEapiKey = Data("e82ckenh8dichen8".utf8)

    /// Exact Swift port of `wy/utils/crypto.js:eapi`.
    static func wyEapiParams(url: String, payload: [String: Any]) throws -> String {
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let text = String(data: jsonData, encoding: .utf8) else {
            throw MusicSDKError.parseError("WY JSON serialization failed")
        }
        return try wyEapiParams(url: url, jsonText: text)
    }

    static func wyEapiParams(url: String, jsonText: String) throws -> String {
        let message = "nobody\(url)use\(jsonText)md5forencrypt"
        let digest = CryptoUtils.md5Hex(message)
        let plain = "\(url)-36cd479b6b5-\(jsonText)-36cd479b6b5-\(digest)"
        let encrypted = try CryptoUtils.aesEncrypt(data: Data(plain.utf8), key: wyEapiKey, isECB: true)
        return encrypted.hexUppercased
    }

    private func searchWY(query: String, page: Int, limit: Int) async throws -> [MusicInfo] {
        try await HTTPClient.withRetry(maxAttempts: 2) {
            let payload: [String: Any] = [
                "keyword": query,
                "needCorrect": "1",
                "channel": "typing",
                "offset": limit * max(0, page - 1),
                "scene": "normal",
                "total": page == 1,
                "limit": limit,
            ]
            let params = try Self.wyEapiParams(url: "/api/search/song/list/page", payload: payload)
            let resp = try await HTTPClient.shared.postForm(
                "http://interface.music.163.com/eapi/batch",
                form: ["params": params],
                headers: [
                    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36",
                    "origin": "https://music.163.com",
                ],
                timeout: 6.0
            )
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["code"]) == 200,
                  let dataObj = body["data"] as? [String: Any] else {
                throw MusicSDKError.apiError("WY search failed")
            }

            let resources = (dataObj["resources"] as? [[String: Any]]) ?? []
            return resources.compactMap { resource -> MusicInfo? in
                guard let baseInfo = resource["baseInfo"] as? [String: Any],
                      let item = baseInfo["simpleSongData"] as? [String: Any] else {
                    return nil
                }
                let songmid = FormatUtils.stringValue(item["id"])
                guard !songmid.isEmpty else { return nil }

                var types: [MusicQualityItem] = []
                var map: [String: MusicQualityMeta] = [:]

                let privilege = item["privilege"] as? [String: Any]
                let maxBrLevel = privilege?["maxBrLevel"] as? String
                let maxbr = FormatUtils.intValue(privilege?["maxbr"])

                if maxBrLevel == "hires" {
                    let hrSize = (item["hr"] as? [String: Any]).flatMap { FormatUtils.int64Value($0["size"]) }
                    let s = hrSize.flatMap { $0 > 0 ? FormatUtils.sizeFormate($0) : nil }
                    types.append(MusicQualityItem(type: .flac24bit, size: s))
                    map[AudioQuality.flac24bit.rawValue] = MusicQualityMeta(size: s)
                }
                if maxbr >= 999_000 {
                    let sqSize = (item["sq"] as? [String: Any]).flatMap { FormatUtils.int64Value($0["size"]) }
                    let s = sqSize.flatMap { $0 > 0 ? FormatUtils.sizeFormate($0) : nil }
                    types.append(MusicQualityItem(type: .flac, size: s))
                    map[AudioQuality.flac.rawValue] = MusicQualityMeta(size: s)
                }
                if maxbr >= 320_000 {
                    let hSize = (item["h"] as? [String: Any]).flatMap { FormatUtils.int64Value($0["size"]) }
                    let s = hSize.flatMap { $0 > 0 ? FormatUtils.sizeFormate($0) : nil }
                    types.append(MusicQualityItem(type: .k320, size: s))
                    map[AudioQuality.k320.rawValue] = MusicQualityMeta(size: s)
                }
                if maxbr >= 128_000 {
                    let lSize = (item["l"] as? [String: Any]).flatMap { FormatUtils.int64Value($0["size"]) }
                    let s = lSize.flatMap { $0 > 0 ? FormatUtils.sizeFormate($0) : nil }
                    types.append(MusicQualityItem(type: .k128, size: s))
                    map[AudioQuality.k128.rawValue] = MusicQualityMeta(size: s)
                }
                types.reverse()

                let al = item["al"] as? [String: Any]
                let ar = item["ar"] as? [[String: Any]]
                let dtMs = FormatUtils.int64Value(item["dt"])
                let interval = dtMs > 0 ? FormatUtils.formatPlayTime(Double(dtMs) / 1000.0) : nil

                return MusicInfo(
                    id: "wy_\(songmid)",
                    name: FormatUtils.decodeName(item["name"] as? String),
                    singer: FormatUtils.formatSingerName(ar, nameKey: "name"),
                    source: .wy,
                    interval: interval,
                    meta: MusicMeta(
                        songId: songmid,
                        albumName: FormatUtils.decodeName(al?["name"] as? String),
                        picUrl: al?["picUrl"] as? String,
                        albumId: FormatUtils.stringValue(al?["id"]),
                        qualitys: types,
                        _qualitys: map
                    )
                )
            }
        }
    }

    // MARK: - Platform 4: Migu Music (`mg/musicSearch.js`)

    /// Exact Swift port of `mg/musicSearch.js:createSignature`.
    static func mgSignature(time: String, query: String) -> (sign: String, deviceId: String) {
        let deviceId = "963B7AA0D21511ED807EE5846EC87D20"
        let signatureMd5 = "6cdc72a439cef99a3418d2a78aa28c73"
        let sign = CryptoUtils.md5Hex("\(query)\(signatureMd5)yyapp2d16148780a1dcc7408e06336b98cfd50\(deviceId)\(time)")
        return (sign, deviceId)
    }

    private func searchMG(query: String, page: Int, limit: Int) async throws -> [MusicInfo] {
        try await HTTPClient.withRetry(maxAttempts: 2) {
            let time = String(Int64(Date().timeIntervalSince1970 * 1000))
            let sig = Self.mgSignature(time: time, query: query)
            let encoded = FormatUtils.urlEncodeComponent(query)
            let url = "https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1&searchSwitch=%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A1%2C%22mvSong%22%3A0%2C%22bestShow%22%3A1%2C%22songlist%22%3A0%2C%22lyricSong%22%3A0%7D&pageSize=\(limit)&text=\(encoded)&pageNo=\(page)&sort=0&sid=USS"
            let resp = try await HTTPClient.shared.get(
                url,
                headers: [
                    "uiVersion": "A_music_3.6.1",
                    "deviceId": sig.deviceId,
                    "timestamp": time,
                    "sign": sig.sign,
                    "channel": "0146921",
                    "User-Agent": "Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30",
                ],
                timeout: 6.0
            )
            let body = try resp.jsonDictionary()
            guard FormatUtils.stringValue(body["code"]) == "000000",
                  let songResultData = body["songResultData"] as? [String: Any],
                  let resultList = songResultData["resultList"] as? [[[String: Any]]] else {
                throw MusicSDKError.apiError("MG search failed")
            }

            var seen = Set<String>()
            var output: [MusicInfo] = []

            for group in resultList {
                for data in group {
                    let songId = FormatUtils.stringValue(data["songId"])
                    let copyrightId = FormatUtils.stringValue(data["copyrightId"])
                    guard !songId.isEmpty, !copyrightId.isEmpty, seen.insert(copyrightId).inserted else {
                        continue
                    }

                    var types: [MusicQualityItem] = []
                    var map: [String: MusicQualityMeta] = [:]

                    if let audioFormats = data["audioFormats"] as? [[String: Any]] {
                        for fmt in audioFormats {
                            let formatType = FormatUtils.stringValue(fmt["formatType"])
                            let rawSize = fmt["asize"] ?? fmt["isize"]
                            let sizeVal = FormatUtils.int64Value(rawSize)
                            let sizeStr = sizeVal > 0 ? FormatUtils.sizeFormate(sizeVal) : nil
                            let quality: AudioQuality
                            switch formatType {
                            case "PQ": quality = .k128
                            case "HQ": quality = .k320
                            case "SQ": quality = .flac
                            case "ZQ24": quality = .flac24bit
                            default: continue
                            }
                            types.append(MusicQualityItem(type: quality, size: sizeStr))
                            map[quality.rawValue] = MusicQualityMeta(size: sizeStr)
                        }
                    }

                    var img: String? = (data["img3"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (data["img2"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (data["img1"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    if let rawImg = img, !rawImg.hasPrefix("http://"), !rawImg.hasPrefix("https://") {
                        img = "http://d.musicapp.migu.cn" + rawImg
                    }

                    let duration = FormatUtils.intValue(data["duration"])
                    let singerList = data["singerList"] as? [[String: Any]]

                    output.append(MusicInfo(
                        id: "mg_\(songId)",
                        name: FormatUtils.decodeName(data["name"] as? String),
                        singer: FormatUtils.formatSingerName(singerList, nameKey: "name"),
                        source: .mg,
                        interval: duration > 0 ? FormatUtils.formatPlayTime(duration) : nil,
                        meta: MusicMeta(
                            songId: songId,
                            albumName: FormatUtils.decodeName(data["album"] as? String),
                            picUrl: img,
                            albumId: FormatUtils.stringValue(data["albumId"]),
                            qualitys: types,
                            _qualitys: map,
                            copyrightId: copyrightId,
                            lrcUrl: data["lrcUrl"] as? String,
                            mrcUrl: data["mrcurl"] as? String,
                            trcUrl: data["trcUrl"] as? String
                        )
                    ))
                }
            }
            return output
        }
    }

    // MARK: - Matching & 9-Tier Ranking (`musicSdk/index.js:findMusic` + `versionChars.ts`)

    private struct Candidate {
        let music: MusicInfo
        let fSinger: String
        let fMusicName: String
        let fAlbumName: String
        let fInterval: Int
        let intervalValid: Bool
    }

    /// Exact port of `musicSdk/index.js:findMusic` matching and priority sorting algorithm.
    static func matchAndRank(target: MusicInfo, sourceLists: [[MusicInfo]]) -> [MusicInfo] {
        let fMusicName = filterStr(target.name).lowercased()
        let fSinger = filterStr(sortSinger(target.singer)).lowercased()
        let fAlbumName = filterStr(target.meta.albumName).lowercased()
        let fInterval = FormatUtils.parseIntervalSeconds(target.interval)
        let targetInterval = target.interval

        func isEqualsInterval(_ intv: Int) -> Bool {
            let lhs = fInterval != 0 ? fInterval : intv
            let rhs = intv != 0 ? intv : fInterval
            return abs(lhs - rhs) <= 5
        }

        func isEqualsVersionMusicNameChar(_ name: String) -> Bool {
            for char in versionChars {
                if name.contains(char) != fMusicName.contains(char) {
                    return false
                }
            }
            return true
        }

        func isIncludesName(_ name: String) -> Bool {
            guard !name.isEmpty, !fMusicName.isEmpty else { return false }
            return (fMusicName.contains(name) || name.contains(fMusicName)) && isEqualsVersionMusicNameChar(name)
        }

        func isIncludesSinger(_ singer: String) -> Bool {
            if fSinger.isEmpty || singer.isEmpty { return true }
            return fSinger.contains(singer) || singer.contains(fSinger)
        }

        func isEqualsAlbum(_ album: String) -> Bool {
            fAlbumName.isEmpty ? true : (fAlbumName == album)
        }

        // Select at most 1 best match per platform via 3-pass scan
        var matchedCandidates: [Candidate] = []
        for list in sourceLists {
            let candidates: [Candidate] = list.map { raw in
                var item = raw
                item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                item.singer = item.singer.trimmingCharacters(in: .whitespacesAndNewlines)
                let cSinger = filterStr(sortSinger(item.singer).lowercased())
                let cName = filterStr(item.name.lowercased())
                let cAlbum = filterStr(item.meta.albumName.lowercased())
                let cInterval = FormatUtils.parseIntervalSeconds(item.interval)
                return Candidate(
                    music: item,
                    fSinger: cSinger,
                    fMusicName: cName,
                    fAlbumName: cAlbum,
                    fInterval: cInterval,
                    intervalValid: isEqualsInterval(cInterval)
                )
            }

            if let hit = candidates.first(where: { $0.intervalValid && $0.fMusicName == fMusicName && isIncludesSinger($0.fSinger) }) {
                matchedCandidates.append(hit)
                continue
            }
            if let hit = candidates.first(where: { $0.intervalValid && $0.fSinger == fSinger && isIncludesName($0.fMusicName) }) {
                matchedCandidates.append(hit)
                continue
            }
            if let hit = candidates.first(where: { $0.intervalValid && isEqualsAlbum($0.fAlbumName) && isIncludesSinger($0.fSinger) && isIncludesName($0.fMusicName) }) {
                matchedCandidates.append(hit)
                continue
            }
        }

        guard !matchedCandidates.isEmpty else { return [] }

        func extract(where predicate: (Candidate) -> Bool) -> [MusicInfo] {
            var matched: [MusicInfo] = []
            var remaining: [Candidate] = []
            for item in matchedCandidates {
                if predicate(item) {
                    matched.append(item.music)
                } else {
                    remaining.append(item)
                }
            }
            matchedCandidates = remaining
            return matched
        }

        // 9-tier priority sort matching `musicSdk/index.js` lines 156-171
        var ranked: [MusicInfo] = []
        ranked.append(contentsOf: extract { $0.fSinger == fSinger && $0.fMusicName == fMusicName && $0.music.interval == targetInterval })
        ranked.append(contentsOf: extract { $0.fMusicName == fMusicName && $0.fSinger == fSinger && $0.fAlbumName == fAlbumName })
        ranked.append(contentsOf: extract { $0.fSinger == fSinger && $0.fMusicName == fMusicName })
        ranked.append(contentsOf: extract { $0.fMusicName == fMusicName && $0.music.interval == targetInterval })
        ranked.append(contentsOf: extract { $0.fSinger == fSinger && $0.music.interval == targetInterval })
        ranked.append(contentsOf: extract { $0.music.interval == targetInterval })
        ranked.append(contentsOf: extract { $0.fMusicName == fMusicName })
        ranked.append(contentsOf: extract { $0.fSinger == fSinger })
        ranked.append(contentsOf: extract { $0.fAlbumName == fAlbumName })
        ranked.append(contentsOf: matchedCandidates.map(\.music))
        return ranked
    }

    private static let singerSplitPattern = #"[、&;；/,，|]"#
    private static let filterStripPattern = #"[\s'.,，&"、()（）`~\-<>|/\]\[!！]"#

    private static func sortSinger(_ singer: String) -> String {
        guard !singer.isEmpty else { return "" }
        guard RegexHelper.test(singerSplitPattern, in: singer) else { return singer }
        let sep = CharacterSet(charactersIn: "、&;；/,，|")
        return singer
            .components(separatedBy: sep)
            .sorted { $0.localizedCompare($1) == .orderedAscending }
            .joined(separator: "、")
    }

    private static func filterStr(_ str: String) -> String {
        RegexHelper.replace(filterStripPattern, in: str, with: "")
    }

    /// Exact port of `src/renderer/utils/musicSdk/versionChars.ts`.
    private static let versionChars: [String] = [
        // 伴奏 / 无人声
        "instrumental", "inst", "karaoke", "backing track", "minus one",
        "minus vocal", "no vocal", "off vocal", "vocal removed",
        "伴奏", "伴唱", "卡拉ok", "纯音乐", "无人声", "去人声", "消音",
        "オフボーカル", "インスト", "반주", "노래방",
        // 现场
        "live", "concert", "tour", "festival", "stage", "session",
        "现场", "演唱会", "巡演", "音乐会", "ライブ", "공연", "라이브",
        // 翻唱
        "cover", "tribute", "rendition", "remake",
        "翻唱", "致敬", "改编", "カバー", "커버",
        // 混音
        "remix", "mix", "club", "dance", "extended", "house", "edm",
        "dj", "dub", "trap", "混音", "重混", "电音", "リミックス", "리믹스",
        // 原声 / 不插电
        "acoustic", "unplugged", "stripped", "原声", "不插电",
        "アコースティック", "어쿠스틱",
        // Demo
        "demo", "小样", "试听", "デモ", "데모",
        // 速度变化
        "slowed", "slowed reverb", "sped up", "speed up", "nightcore",
        "慢速", "加速", "变速", "ナイトコア",
        // 特殊乐器版
        "piano", "guitar", "orchestra", "symphony", "violin",
        "钢琴", "吉他", "管弦乐", "小提琴", "ピアノ", "ギター", "피아노", "기타",
    ]
}
