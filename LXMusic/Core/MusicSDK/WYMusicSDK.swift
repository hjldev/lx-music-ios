import Foundation

/// Native Swift port of NetEase Cloud Music SDK (`src/renderer/utils/musicSdk/wy/`).
final class WYMusicSDK: MusicSDK, @unchecked Sendable {
    let source: MusicSource = .wy

    let songListSortOptions: [SongListSortOption] = [
        SongListSortOption(id: "hot", name: "最热"),
    ]

    let leaderboardBoards: [LeaderboardBoard] = [
        ("19723756", "飙升榜"), ("3779629", "新歌榜"), ("2884035", "原创榜"), ("3778678", "热歌榜"),
        ("991319590", "说唱榜"), ("71384707", "古典榜"), ("1978921795", "电音榜"), ("5453912201", "黑胶VIP爱听榜"),
        ("71385702", "ACG榜"), ("745956260", "韩语榜"), ("10520166", "国电榜"), ("180106", "UK排行榜周榜"),
        ("60198", "美国Billboard榜"), ("3812895", "Beatport全球电子舞曲榜"), ("21845217", "KTV唛榜"),
        ("60131", "日本Oricon榜"), ("2809513713", "欧美热歌榜"), ("2809577409", "欧美新歌榜"),
        ("27135204", "法国 NRJ Vos Hits 周榜"), ("3001835560", "ACG动画榜"), ("3001795926", "ACG游戏榜"),
        ("3001890046", "ACG VOCALOID榜"), ("3112516681", "中国新乡村音乐排行榜"), ("5059644681", "日语榜"),
        ("5059633707", "摇滚榜"), ("5059642708", "国风榜"), ("5338990334", "潜力爆款榜"),
        ("5059661515", "民谣榜"), ("6688069460", "听歌识曲榜"), ("6723173524", "网络热歌榜"),
        ("6732051320", "俄语榜"), ("6732014811", "越南语榜"), ("6886768100", "中文DJ榜"),
        ("6939992364", "俄罗斯top hit流行音乐榜"), ("7095271308", "泰语榜"), ("7356827205", "BEAT排行榜"),
        ("7603212484", "LOOK直播歌曲榜"), ("7775163417", "赏音榜"), ("7785123708", "黑胶VIP新歌榜"),
        ("7785066739", "黑胶VIP热歌榜"), ("7785091694", "黑胶VIP爱搜榜"),
    ].map { LeaderboardBoard(id: "wy__\($0.0)", name: $0.1, bangid: $0.0, source: .wy) }

    // MARK: - Crypto (`wy/utils/crypto.js`)

    private static let iv = Data("0102030405060708".utf8)
    private static let presetKey = Data("0CoJUm6Qyw8W8jud".utf8)
    private static let linuxapiKey = Data("rFgB&h#%2?^eDg:Q".utf8)
    private static let eapiKey = Data("e82ckenh8dichen8".utf8)
    private static let base62Chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
    private static let rsaPublicKeyPKCS1Base64 = "MIGJAoGBAOC1CfYlnfhkLbw1ZikBR33yJnfsFStf9orOYVu3tyUVKzqxeodq6opap20uQXYp7E7jQfVhNfzPaVKAEE4DEuy9qSVXyThwEUr2ydBcT38MNoW3pGvuJVkyV1zOELQk2BPP5IddPoIEe5fd71J0HVRrjiidxpNbPs4EYtsKIrjnAgMBAAE="

    private static let linuxUA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36"

    static func weapi(_ object: [String: Any]) throws -> [String: String] {
        let textData = try JSONSerialization.data(withJSONObject: object, options: [])
        let rand = CryptoUtils.randomBytes(16)
        let secretKeyBytes = rand.map { base62Chars[Int($0) % 62] }
        let secretKey = Data(secretKeyBytes)

        let enc1 = try CryptoUtils.aesEncrypt(data: textData, key: presetKey, iv: iv, isECB: false).base64EncodedString()
        let params = try CryptoUtils.aesEncrypt(data: Data(enc1.utf8), key: secretKey, iv: iv, isECB: false).base64EncodedString()

        let rsaInput = Data(repeating: 0, count: 112) + Data(secretKeyBytes.reversed())
        guard let pubDER = Data(base64Encoded: rsaPublicKeyPKCS1Base64) else {
            throw CryptoUtils.CryptoError.rsaKeyInvalid
        }
        let encSecKey = try CryptoUtils.rsaEncryptNoPadding(data: rsaInput, publicKeyDER: pubDER).hexLowercased
        return ["params": params, "encSecKey": encSecKey]
    }

    static func linuxapi(_ object: [String: Any]) throws -> [String: String] {
        let textData = try JSONSerialization.data(withJSONObject: object, options: [])
        let encrypted = try CryptoUtils.aesEncrypt(data: textData, key: linuxapiKey, isECB: true)
        return ["eparams": encrypted.hexUppercased]
    }

    static func eapi(url: String, object: [String: Any]) throws -> [String: String] {
        let jsonData = try JSONSerialization.data(withJSONObject: object, options: [])
        let text = String(data: jsonData, encoding: .utf8) ?? "{}"
        let message = "nobody\(url)use\(text)md5forencrypt"
        let digest = CryptoUtils.md5Hex(message)
        let payload = "\(url)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"
        let encrypted = try CryptoUtils.aesEncrypt(data: Data(payload.utf8), key: eapiKey, isECB: true)
        return ["params": encrypted.hexUppercased]
    }

    private func eapiBatchRequest(url: String, data: [String: Any]) async throws -> HTTPResponse {
        let form = try Self.eapi(url: url, object: data)
        return try await HTTPClient.shared.postForm(
            "http://interface.music.163.com/eapi/batch",
            form: form,
            headers: [
                "User-Agent": Self.linuxUA,
                "origin": "https://music.163.com",
            ]
        )
    }

    // MARK: - Quality & Track Mapping

    private func extractQualities(song: [String: Any], privilege: [String: Any], includeSQSize: Bool = true) -> ([MusicQualityItem], [String: MusicQualityMeta]) {
        var types: [MusicQualityItem] = []
        var map: [String: MusicQualityMeta] = [:]

        let maxBrLevel = FormatUtils.stringValue(privilege["maxBrLevel"])
        if maxBrLevel == "hires" {
            let hrSize = (song["hr"] as? [String: Any]).map { FormatUtils.sizeFormate(FormatUtils.int64Value($0["size"])) }
            types.append(MusicQualityItem(type: .flac24bit, size: hrSize))
            map[AudioQuality.flac24bit.rawValue] = MusicQualityMeta(size: hrSize)
        }

        let maxbr = FormatUtils.intValue(privilege["maxbr"])
        if maxbr >= 999000 {
            let sqSize: String? = includeSQSize
                ? (song["sq"] as? [String: Any]).map { FormatUtils.sizeFormate(FormatUtils.int64Value($0["size"])) }
                : nil
            types.append(MusicQualityItem(type: .flac, size: sqSize))
            map[AudioQuality.flac.rawValue] = MusicQualityMeta(size: sqSize)
        }
        if maxbr >= 320000 {
            let hSize = (song["h"] as? [String: Any]).map { FormatUtils.sizeFormate(FormatUtils.int64Value($0["size"])) }
            types.append(MusicQualityItem(type: .k320, size: hSize))
            map[AudioQuality.k320.rawValue] = MusicQualityMeta(size: hSize)
        }
        if maxbr >= 128000 || types.isEmpty {
            let lSize = (song["l"] as? [String: Any]).map { FormatUtils.sizeFormate(FormatUtils.int64Value($0["size"])) }
            types.append(MusicQualityItem(type: .k128, size: lSize))
            map[AudioQuality.k128.rawValue] = MusicQualityMeta(size: lSize)
        }

        types.reverse()
        return (types, map)
    }

    private func mapSong(song: [String: Any], privilege: [String: Any], includeSQSize: Bool = true) -> MusicInfo? {
        let songmid = FormatUtils.stringValue(song["id"])
        guard !songmid.isEmpty else { return nil }
        let (types, map) = extractQualities(song: song, privilege: privilege, includeSQSize: includeSQSize)
        let dt = Double(FormatUtils.int64Value(song["dt"])) / 1000.0
        let al = (song["al"] as? [String: Any]) ?? [:]
        let picUrl = al["picUrl"] as? String

        if let pc = song["pc"] as? [String: Any] {
            return MusicInfo(
                id: "wy_\(songmid)",
                name: FormatUtils.stringValue(pc["sn"]),
                singer: FormatUtils.stringValue(pc["ar"]),
                source: .wy,
                interval: FormatUtils.formatPlayTime(dt),
                meta: MusicMeta(
                    songId: songmid,
                    albumName: FormatUtils.stringValue(pc["alb"]),
                    picUrl: picUrl,
                    albumId: FormatUtils.stringValue(al["id"]),
                    qualitys: types,
                    _qualitys: map
                )
            )
        }

        let ar = (song["ar"] as? [[String: Any]]) ?? []
        return MusicInfo(
            id: "wy_\(songmid)",
            name: FormatUtils.decodeName(song["name"] as? String),
            singer: FormatUtils.formatSingerName(ar, nameKey: "name"),
            source: .wy,
            interval: FormatUtils.formatPlayTime(dt),
            meta: MusicMeta(
                songId: songmid,
                albumName: FormatUtils.decodeName(al["name"] as? String),
                picUrl: picUrl,
                albumId: FormatUtils.stringValue(al["id"]),
                qualitys: types,
                _qualitys: map
            )
        )
    }

    // MARK: - Search (`wy/musicSearch.js`)

    func searchMusic(query: String, page: Int, limit: Int = 30) async throws -> MusicSearchPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let payload: [String: Any] = [
                "keyword": query,
                "needCorrect": "1",
                "channel": "typing",
                "offset": limit * max(0, page - 1),
                "scene": "normal",
                "total": page == 1,
                "limit": limit,
            ]
            let resp = try await self.eapiBatchRequest(url: "/api/search/song/list/page", data: payload)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["code"]) == 200,
                  let data = body["data"] as? [String: Any] else {
                throw MusicSDKError.apiError("WY search failed")
            }
            let resources = (data["resources"] as? [[String: Any]]) ?? []
            let list: [MusicInfo] = resources.compactMap { res in
                guard let baseInfo = res["baseInfo"] as? [String: Any],
                      let song = baseInfo["simpleSongData"] as? [String: Any] else { return nil }
                let privilege = (song["privilege"] as? [String: Any]) ?? [:]
                return self.mapSong(song: song, privilege: privilege)
            }
            let total = FormatUtils.intValue(data["totalCount"])
            let allPage = max(1, Int(ceil(Double(total) / Double(max(1, limit)))))
            return MusicSearchPage(list: list, page: page, allPage: allPage, limit: limit, total: total, source: .wy)
        }
    }

    func getHotSearch() async throws -> [String] {
        let resp = try await eapiBatchRequest(url: "/api/search/chart/detail", data: ["id": "HOT_SEARCH_SONG#@#"])
        let body = try resp.jsonDictionary()
        guard resp.statusCode == 200, FormatUtils.intValue(body["code"]) == 200,
              let data = body["data"] as? [String: Any],
              let itemList = data["itemList"] as? [[String: Any]] else {
            throw MusicSDKError.apiError("获取网易云热搜词失败")
        }
        return itemList.compactMap { $0["searchWord"] as? String }
    }

    func getTipSearch(query: String) async throws -> [String] {
        let form = try Self.weapi(["s": query])
        let resp = try await HTTPClient.shared.postForm(
            "https://music.163.com/weapi/search/suggest/web",
            form: form,
            headers: [
                "referer": "https://music.163.com/",
                "origin": "https://music.163.com/",
            ]
        )
        let body = try resp.jsonDictionary()
        guard resp.statusCode == 200, FormatUtils.intValue(body["code"]) == 200,
              let result = body["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            return []
        }
        return songs.map { song in
            let name = FormatUtils.stringValue(song["name"])
            let artists = song["artists"] as? [[String: Any]]
            let singer = FormatUtils.formatSingerName(artists, nameKey: "name")
            return singer.isEmpty ? name : "\(name) - \(singer)"
        }
    }

    // MARK: - MusicDetail Batch (`wy/musicDetail.js`)

    func fetchSongsDetail(ids: [Int64]) async throws -> [MusicInfo] {
        guard !ids.isEmpty else { return [] }
        let chunks = stride(from: 0, to: ids.count, by: 1000).map {
            Array(ids[$0..<min($0 + 1000, ids.count)])
        }

        var allTracks: [MusicInfo] = []
        for chunk in chunks {
            let cParam = "[" + chunk.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
            let idsParam = "[" + chunk.map(String.init).joined(separator: ",") + "]"
            let form = try Self.weapi(["c": cParam, "ids": idsParam])
            let resp = try await HTTPClient.shared.postForm(
                "https://music.163.com/weapi/v3/song/detail",
                form: form,
                headers: [
                    "User-Agent": Self.linuxUA,
                    "origin": "https://music.163.com",
                ]
            )
            let body = try resp.jsonDictionary()
            guard resp.statusCode == 200, FormatUtils.intValue(body["code"]) == 200,
                  let songs = body["songs"] as? [[String: Any]],
                  let privileges = body["privileges"] as? [[String: Any]] else {
                continue
            }

            var privById: [Int64: [String: Any]] = [:]
            for p in privileges {
                privById[FormatUtils.int64Value(p["id"])] = p
            }

            for (idx, song) in songs.enumerated() {
                let sid = FormatUtils.int64Value(song["id"])
                let priv: [String: Any]?
                if idx < privileges.count && FormatUtils.int64Value(privileges[idx]["id"]) == sid {
                    priv = privileges[idx]
                } else {
                    priv = privById[sid]
                }
                if let priv, let track = mapSong(song: song, privilege: priv) {
                    allTracks.append(track)
                }
            }
        }
        return allTracks
    }

    // MARK: - Leaderboard (`wy/leaderboard.js`)

    func getLeaderboardTracks(bangId: String, page: Int) async throws -> LeaderboardPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let form = try Self.weapi(["id": bangId, "n": 100000, "p": 1])
            let resp = try await HTTPClient.shared.postForm("https://music.163.com/weapi/v3/playlist/detail", form: form)
            let body = try resp.jsonDictionary()
            guard resp.statusCode == 200, FormatUtils.intValue(body["code"]) == 200,
                  let playlist = body["playlist"] as? [String: Any],
                  let trackIds = playlist["trackIds"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("WY leaderboard failed")
            }
            let ids = trackIds.map { FormatUtils.int64Value($0["id"]) }.filter { $0 > 0 }
            let tracks = try await self.fetchSongsDetail(ids: ids)
            return LeaderboardPage(list: tracks, page: page, limit: 100000, total: tracks.count, source: .wy)
        }
    }

    // MARK: - SongList (`wy/songList.js`)

    func getSongListTags() async throws -> SongListTagsResult {
        async let catTask = fetchWYTagGroups()
        async let hotTask = fetchWYHotTags()
        let (groups, hot) = try await (catTask, hotTask)
        return SongListTagsResult(hotTag: hot, tags: groups, source: .wy)
    }

    private func fetchWYTagGroups() async throws -> [SongListTagGroup] {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let form = try Self.weapi([:])
            let resp = try await HTTPClient.shared.postForm("https://music.163.com/weapi/playlist/catalogue", form: form)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["code"]) == 200,
                  let categories = body["categories"] as? [String: String],
                  let sub = body["sub"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("WY catalogue failed")
            }
            var grouped: [String: [SongListTagItem]] = [:]
            for item in sub {
                let catKey = FormatUtils.stringValue(item["category"])
                let catName = categories[catKey] ?? ""
                let tagName = FormatUtils.stringValue(item["name"])
                grouped[catKey, default: []].append(SongListTagItem(
                    id: tagName,
                    name: tagName,
                    parentId: catName,
                    parentName: catName,
                    source: .wy
                ))
            }
            return categories.keys.sorted().map { key in
                SongListTagGroup(name: categories[key] ?? key, list: grouped[key] ?? [])
            }
        }
    }

    private func fetchWYHotTags() async throws -> [SongListTagItem] {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let form = try Self.weapi([:])
            let resp = try await HTTPClient.shared.postForm("https://music.163.com/weapi/playlist/hottags", form: form)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["code"]) == 200,
                  let tags = body["tags"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("WY hottags failed")
            }
            return tags.compactMap { entry in
                guard let pt = entry["playlistTag"] as? [String: Any] else { return nil }
                let name = FormatUtils.stringValue(pt["name"])
                return name.isEmpty ? nil : SongListTagItem(id: name, name: name, source: .wy)
            }
        }
    }

    func getSongList(sortId: String, tagId: String?, page: Int) async throws -> SongListSearchPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let limit = 30
            let cat = (tagId?.isEmpty == false) ? tagId! : "全部"
            let form = try Self.weapi([
                "cat": cat,
                "order": sortId,
                "limit": limit,
                "offset": limit * max(0, page - 1),
                "total": true,
            ])
            let resp = try await HTTPClient.shared.postForm("https://music.163.com/weapi/playlist/list", form: form)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["code"]) == 200,
                  let playlists = body["playlists"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("WY playlist/list failed")
            }
            let list = self.parseSongListItems(playlists)
            return SongListSearchPage(list: list, page: page, limit: limit, total: FormatUtils.intValue(body["total"]), source: .wy)
        }
    }

    private func parseSongListItems(_ raw: [[String: Any]]) -> [OnlineSongListItem] {
        raw.map { item in
            let creator = (item["creator"] as? [String: Any]) ?? [:]
            let createTime = FormatUtils.int64Value(item["createTime"])
            return OnlineSongListItem(
                id: FormatUtils.stringValue(item["id"]),
                name: FormatUtils.decodeName(item["name"] as? String),
                author: FormatUtils.decodeName(creator["nickname"] as? String),
                img: item["coverImgUrl"] as? String,
                playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(item["playCount"])),
                desc: FormatUtils.decodeName(item["description"] as? String),
                total: FormatUtils.intValue(item["trackCount"]),
                time: createTime > 0 ? FormatUtils.formatDateYMD(milliseconds: createTime) : nil,
                source: .wy
            )
        }
    }

    func searchSongList(query: String, page: Int, limit: Int = 20) async throws -> SongListSearchPage {
        let resp = try await eapiBatchRequest(url: "/api/cloudsearch/pc", data: [
            "s": query,
            "type": 1000,
            "limit": limit,
            "total": page == 1,
            "offset": limit * max(0, page - 1),
        ])
        let body = try resp.jsonDictionary()
        guard FormatUtils.intValue(body["code"]) == 200,
              let result = body["result"] as? [String: Any],
              let playlists = result["playlists"] as? [[String: Any]] else {
            throw MusicSDKError.apiError("WY searchSongList failed")
        }
        return SongListSearchPage(
            list: parseSongListItems(playlists),
            page: page,
            limit: limit,
            total: FormatUtils.intValue(result["playlistCount"]),
            source: .wy
        )
    }

    private func resolveListIdAndCookie(_ raw: String) async throws -> (id: String, cookie: String) {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var cookie = "MUSIC_U="
        if input.contains("###") {
            let parts = input.components(separatedBy: "###")
            input = parts[0]
            if parts.count >= 2 { cookie = "MUSIC_U=\(parts[1])" }
        }
        guard RegexHelper.test(#"[?&:/]"#, in: input) else {
            return (input, cookie)
        }
        if let m = RegexHelper.firstMatch(#"(?:\?|&)id=(\d+)"#, in: input), m.count >= 2 { return (m[1], cookie) }
        if let m = RegexHelper.firstMatch(#"/playlist/(\d+)/\d+/"#, in: input), m.count >= 2 { return (m[1], cookie) }

        let resp = try await HTTPClient.shared.get(input, followRedirects: false)
        let loc = resp.header("location") ?? input
        if let m = RegexHelper.firstMatch(#"(?:\?|&)id=(\d+)"#, in: loc), m.count >= 2 { return (m[1], cookie) }
        if let m = RegexHelper.firstMatch(#"/playlist/(\d+)/\d+/"#, in: loc), m.count >= 2 { return (m[1], cookie) }
        throw MusicSDKError.parseError("无法解析网易云歌单链接")
    }

    func getSongListDetail(idOrUrl: String, page: Int) async throws -> SongListDetailPage {
        let (id, cookie) = try await resolveListIdAndCookie(idOrUrl)
        return try await HTTPClient.withRetry(maxAttempts: 3) {
            let form = try Self.linuxapi([
                "method": "POST",
                "url": "https://music.163.com/api/v3/playlist/detail",
                "params": ["id": id, "n": 100000, "s": 8],
            ])
            let resp = try await HTTPClient.shared.postForm(
                "https://music.163.com/api/linux/forward",
                form: form,
                headers: ["User-Agent": Self.linuxUA, "Cookie": cookie]
            )
            let body = try resp.jsonDictionary()
            guard resp.statusCode == 200, FormatUtils.intValue(body["code"]) == 200,
                  let playlist = body["playlist"] as? [String: Any] else {
                throw MusicSDKError.apiError("获取网易云歌单详情失败")
            }

            let trackIds = (playlist["trackIds"] as? [[String: Any]]) ?? []
            let privileges = (body["privileges"] as? [[String: Any]]) ?? []
            let limit = 1000
            let rangeStart = max(0, page - 1) * limit

            let list: [MusicInfo]
            if trackIds.count == privileges.count, let tracks = playlist["tracks"] as? [[String: Any]], tracks.count == privileges.count {
                list = zip(tracks, privileges).compactMap { self.mapSong(song: $0.0, privilege: $0.1, includeSQSize: false) }
            } else {
                let end = min(rangeStart + limit, trackIds.count)
                if rangeStart < end {
                    let sliceIds = trackIds[rangeStart..<end].map { FormatUtils.int64Value($0["id"]) }.filter { $0 > 0 }
                    list = try await self.fetchSongsDetail(ids: sliceIds)
                } else {
                    list = []
                }
            }

            let creator = (playlist["creator"] as? [String: Any]) ?? [:]
            let info = OnlineSongListInfo(
                name: FormatUtils.decodeName(playlist["name"] as? String),
                img: playlist["coverImgUrl"] as? String,
                desc: FormatUtils.decodeName(playlist["description"] as? String),
                author: FormatUtils.decodeName(creator["nickname"] as? String),
                playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(playlist["playCount"]))
            )
            return SongListDetailPage(list: list, page: page, limit: limit, total: trackIds.count, source: .wy, info: info)
        }
    }

    // MARK: - Pic (`wy/musicInfo.js`)

    func getPic(musicInfo: MusicInfo) async throws -> String {
        if let pic = musicInfo.meta.picUrl, !pic.isEmpty { return pic }
        guard let numId = Int64(musicInfo.meta.songId) else { throw MusicSDKError.picNotFound }
        let tracks = try await fetchSongsDetail(ids: [numId])
        if let pic = tracks.first?.meta.picUrl, !pic.isEmpty { return pic }
        throw MusicSDKError.picNotFound
    }

    // MARK: - Lyric (`wy/lyric.js`)

    func getLyric(musicInfo: MusicInfo) async throws -> LyricInfo {
        let form = try Self.eapi(url: "/api/song/lyric/v1", object: [
            "id": musicInfo.meta.songId,
            "cp": false,
            "tv": 0, "lv": 0, "rv": 0, "kv": 0,
            "yv": 0, "ytv": 0, "yrv": 0,
        ])
        let resp = try await HTTPClient.shared.postForm(
            "https://interface3.music.163.com/eapi/song/lyric/v1",
            form: form,
            headers: [
                "User-Agent": Self.linuxUA,
                "origin": "https://music.163.com",
            ]
        )
        let body = try resp.jsonDictionary()
        guard FormatUtils.intValue(body["code"]) == 200,
              let lrcObj = body["lrc"] as? [String: Any],
              let rawLrc = lrcObj["lyric"] as? String, !rawLrc.isEmpty else {
            throw MusicSDKError.lyricNotFound
        }

        let rawTlrc = (body["tlyric"] as? [String: Any])?["lyric"] as? String
        let rawYrc = (body["yrc"] as? [String: Any])?["lyric"] as? String
        let rawYtlrc = (body["ytlrc"] as? [String: Any])?["lyric"] as? String

        let fixed = Self.fixTimeLabels(lrc: rawLrc, tlrc: rawTlrc)
        let info = Self.parseWYLyric(
            ylrc: rawYrc, ytlrc: rawYtlrc,
            lrc: fixed.lrc, tlrc: fixed.tlrc
        )
        guard !info.lyric.isEmpty else { throw MusicSDKError.lyricNotFound }
        return info
    }

    private static func fixTimeLabels(lrc: String, tlrc: String?) -> (lrc: String, tlrc: String?) {
        let newLrc = RegexHelper.replace(#"\[(\d{2}:\d{2}):(\d{2})\]"#, in: lrc, with: "[$1.$2]")
        let newTlrc = tlrc.map { RegexHelper.replace(#"\[(\d{2}:\d{2}):(\d{2})\]"#, in: $0, with: "[$1.$2]") }
        return (newLrc, newTlrc)
    }

    static func parseWYLyric(
        ylrc: String?, ytlrc: String?,
        lrc: String?, tlrc: String?
    ) -> LyricInfo {
        if let ylrc, let lines = parseHeaderInfo(ylrc) {
            let parsed = parseYRCBody(lines)
            var tlyric = ""
            if let ytlrc, let tLines = parseHeaderInfo(ytlrc) {
                tlyric = fixWYTimeTags(reference: parsed.lyric, target: tLines.joined(separator: "\n"))
            } else if let tlrc, let tLines = parseHeaderInfo(tlrc) {
                tlyric = fixWYTimeTags(reference: parsed.lyric, target: tLines.joined(separator: "\n"))
            }
            let headers = lines.filter { RegexHelper.test(#"^\[[\d:.]+\]"#, in: $0) }.joined(separator: "\n")
            let combinedLyric = headers.isEmpty ? parsed.lyric : "\(headers)\n\(parsed.lyric)"
            return LyricInfo(lyric: combinedLyric, tlyric: tlyric, lxlyric: parsed.lxlyric)
        }

        let plain = lrc.flatMap(parseHeaderInfo)?.joined(separator: "\n") ?? ""
        let trans = tlrc.flatMap(parseHeaderInfo)?.joined(separator: "\n") ?? ""
        return LyricInfo(lyric: plain, tlyric: trans, lxlyric: "")
    }

    private static func msFormat(_ timeMs: Int, pad3: Bool = true) -> String {
        var ms = String(format: pad3 ? "%03d" : "%02d", timeMs % 1000)
        if !pad3 && ms.count > 2 { ms = String(ms.prefix(2)) }
        let sec = timeMs / 1000
        let m = String(format: "%02d", sec / 60)
        let s = String(format: "%02d", sec % 60)
        return "[\(m):\(s).\(ms)]"
    }

    private static func parseHeaderInfo(_ raw: String) -> [String]? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r", with: "")
        guard !cleaned.isEmpty else { return nil }
        let isPad3 = RegexHelper.test(#"\[\d+:\d+\.\d{3}\]"#, in: cleaned) || !RegexHelper.test(#"\[\d+:\d+\.\d{2}\]"#, in: cleaned)

        return cleaned.components(separatedBy: "\n").map { line in
            guard line.hasPrefix("{\"") else { return line }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cArr = obj["c"] as? [[String: Any]] else {
                return ""
            }
            let t = FormatUtils.intValue(obj["t"])
            let tag = msFormat(t, pad3: isPad3)
            let text = cArr.compactMap { $0["tx"] as? String }.joined()
            return "\(tag)\(text)"
        }
    }

    private static func parseYRCBody(_ lines: [String]) -> (lyric: String, lxlyric: String) {
        var lrcLines: [String] = []
        var lxLines: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let m = RegexHelper.firstMatch(#"^\[(\d+),\d+\]"#, in: line), m.count >= 2, let startMs = Int(m[1]) {
                let startTag = msFormat(startMs, pad3: true)
                let words = String(line.dropFirst(m[0].count))
                let plain = RegexHelper.replace(#"\(\d+,\d+,\d+\)"#, in: words, with: "")
                lrcLines.append("\(startTag)\(plain)")

                let wordMatches = RegexHelper.allMatches(#"\((\d+),(\d+),\d+\)"#, in: words)
                guard !wordMatches.isEmpty else { continue }
                let parts = splitWordsAfterTags(words, pattern: #"\(\d+,\d+,\d+\)"#)
                var built = ""
                for (idx, wm) in wordMatches.enumerated() where wm.count >= 3 {
                    let relStart = max((Int(wm[1]) ?? startMs) - startMs, 0)
                    let dur = Int(wm[2]) ?? 0
                    let text = idx < parts.count ? parts[idx] : ""
                    built += "<\(relStart),\(dur)>\(text)"
                }
                lxLines.append("\(startTag)\(built)")
            } else if line.hasPrefix("[offset") {
                lrcLines.append(line)
                lxLines.append(line)
            }
        }
        return (lrcLines.joined(separator: "\n"), lxLines.joined(separator: "\n"))
    }

    private static func splitWordsAfterTags(_ str: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = str as NSString
        let matches = regex.matches(in: str, range: NSRange(location: 0, length: ns.length))
        var parts: [String] = []
        for i in 0..<matches.count {
            let start = matches[i].range.location + matches[i].range.length
            let end = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            parts.append(ns.substring(with: NSRange(location: start, length: max(0, end - start))))
        }
        return parts
    }

    private static func wyIntv(_ raw: String) -> Int {
        var str = raw
        if !str.contains(".") { str += ".0" }
        var arr = str.components(separatedBy: CharacterSet(charactersIn: ":."))
        while arr.count < 3 { arr.insert("0", at: 0) }
        return (Int(arr[0]) ?? 0) * 3_600_000 + (Int(arr[1]) ?? 0) * 1000 + (Int(arr[2]) ?? 0)
    }

    private static func fixWYTimeTags(reference: String, target: String) -> String {
        var refLines = reference.components(separatedBy: "\n")
        var output: [String] = []
        for line in target.components(separatedBy: "\n") {
            guard let m = RegexHelper.firstMatch(#"^\[([\d:.]+)\]"#, in: line), m.count >= 2 else { continue }
            let words = String(line.dropFirst(m[0].count))
            guard !words.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let t1 = wyIntv(m[1])
            var temp: [String] = []
            while !refLines.isEmpty {
                let refLine = refLines.removeFirst()
                guard let rm = RegexHelper.firstMatch(#"^\[([\d:.]+)\]"#, in: refLine), rm.count >= 2 else { continue }
                let t2 = wyIntv(rm[1])
                if abs(t1 - t2) < 100 {
                    let fixed = (rm[0] + words).trimmingCharacters(in: .whitespaces)
                    if !fixed.isEmpty { output.append(fixed) }
                    break
                }
                temp.append(refLine)
            }
            refLines = temp + refLines
        }
        return output.joined(separator: "\n")
    }
}
