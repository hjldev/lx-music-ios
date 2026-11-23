import Foundation

/// Native Swift port of Migu Music SDK (`src/renderer/utils/musicSdk/mg/`).
final class MGMusicSDK: MusicSDK, @unchecked Sendable {
    let source: MusicSource = .mg

    let songListSortOptions: [SongListSortOption] = [
        SongListSortOption(id: "15127315", name: "推荐"),
    ]

    let leaderboardBoards: [LeaderboardBoard] = [
        ("27553319", "新歌榜"), ("27186466", "热歌榜"), ("27553408", "原创榜"),
        ("75959118", "音乐风向榜"), ("76557036", "彩铃分贝榜"), ("76557745", "会员臻爱榜"),
        ("23189800", "港台榜"), ("23189399", "内地榜"), ("19190036", "欧美榜"),
        ("83176390", "国风金曲榜"),
    ].map { LeaderboardBoard(id: "mg__\($0.0)", name: $0.1, bangid: $0.0, source: .mg) }

    private static let deviceId = "963B7AA0D21511ED807EE5846EC87D20"
    private static let signatureMd5 = "6cdc72a439cef99a3418d2a78aa28c73"
    private static let signatureSalt = "yyapp2d16148780a1dcc7408e06336b98cfd50"

    private static let mobileHeaders = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1",
        "Referer": "https://m.music.migu.cn/",
    ]

    static func createSignature(time: String, query: String) -> String {
        CryptoUtils.md5Hex("\(query)\(signatureMd5)\(signatureSalt)\(deviceId)\(time)")
    }

    private func searchHeaders(for query: String) -> [String: String] {
        let time = String(Int64(Date().timeIntervalSince1970 * 1000))
        let sign = Self.createSignature(time: time, query: query)
        return [
            "uiVersion": "A_music_3.6.1",
            "deviceId": Self.deviceId,
            "timestamp": time,
            "sign": sign,
            "channel": "0146921",
            "User-Agent": "Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30",
        ]
    }

    private func mgFetch(_ url: String, method: String = "GET", headers: [String: String] = [:], form: [String: String]? = nil) async throws -> [String: Any] {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let payload: HTTPClient.BodyPayload = form.map { .form($0) } ?? .none
            let resp = try await HTTPClient.shared.request(url, method: method, headers: headers, body: payload)
            guard resp.statusCode == 200 else {
                throw MusicSDKError.httpStatus(resp.statusCode, "MG HTTP error")
            }
            let body = try resp.jsonDictionary()
            let code = (body["code"] as? String) ?? (body["returnCode"] as? String) ?? ""
            guard code == "000000" else {
                throw MusicSDKError.apiError((body["info"] as? String) ?? "MG code \(code)")
            }
            if let data = body["data"] as? [String: Any] { return data }
            return body
        }
    }

    // MARK: - Search (`mg/musicSearch.js`)

    func searchMusic(query: String, page: Int, limit: Int = 20) async throws -> MusicSearchPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let encoded = FormatUtils.urlEncodeComponent(query)
            let url = "https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1&searchSwitch=%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A1%2C%22mvSong%22%3A0%2C%22bestShow%22%3A1%2C%22songlist%22%3A0%2C%22lyricSong%22%3A0%7D&pageSize=\(limit)&text=\(encoded)&pageNo=\(page)&sort=0&sid=USS"
            let resp = try await HTTPClient.shared.get(url, headers: self.searchHeaders(for: query))
            let body = try resp.jsonDictionary()
            guard (body["code"] as? String) == "000000" else {
                throw MusicSDKError.apiError((body["info"] as? String) ?? "咪咕搜索失败")
            }
            let songResult = (body["songResultData"] as? [String: Any]) ?? [:]
            let resultList2D = (songResult["resultList"] as? [[[String: Any]]]) ?? []

            var seen = Set<String>()
            var list: [MusicInfo] = []
            for group in resultList2D {
                for data in group {
                    let songId = FormatUtils.stringValue(data["songId"])
                    let copyrightId = FormatUtils.stringValue(data["copyrightId"])
                    guard !songId.isEmpty, !copyrightId.isEmpty, seen.insert(copyrightId).inserted else { continue }

                    var types: [MusicQualityItem] = []
                    var map: [String: MusicQualityMeta] = [:]
                    if let formats = data["audioFormats"] as? [[String: Any]] {
                        for f in formats {
                            let ft = FormatUtils.stringValue(f["formatType"])
                            let rawSize = FormatUtils.int64Value(f["asize"] ?? f["isize"])
                            let size = rawSize > 0 ? FormatUtils.sizeFormate(rawSize) : nil
                            let q: AudioQuality
                            switch ft {
                            case "PQ": q = .k128
                            case "HQ": q = .k320
                            case "SQ": q = .flac
                            case "ZQ24", "ZQ": q = .flac24bit
                            default: continue
                            }
                            types.append(MusicQualityItem(type: q, size: size))
                            map[q.rawValue] = MusicQualityMeta(size: size)
                        }
                    }

                    var img = (data["img3"] as? String) ?? (data["img2"] as? String) ?? (data["img1"] as? String)
                    if let currentImg = img, !currentImg.isEmpty, !currentImg.hasPrefix("http") {
                        img = "http://d.musicapp.migu.cn" + currentImg
                    }

                    let singerList = data["singerList"] as? [[String: Any]]
                    list.append(MusicInfo(
                        id: "mg_\(songId)",
                        name: FormatUtils.decodeName(data["name"] as? String),
                        singer: FormatUtils.formatSingerName(singerList, nameKey: "name"),
                        source: .mg,
                        interval: FormatUtils.formatPlayTime(FormatUtils.intValue(data["duration"])),
                        meta: MusicMeta(
                            songId: songId,
                            albumName: FormatUtils.decodeName(data["album"] as? String),
                            picUrl: img,
                            albumId: FormatUtils.stringValue(data["albumId"]),
                            qualitys: types,
                            _qualitys: map,
                            copyrightId: copyrightId,
                            lrcUrl: data["lrcUrl"] as? String,
                            mrcUrl: (data["mrcurl"] as? String) ?? (data["mrcUrl"] as? String),
                            trcUrl: data["trcUrl"] as? String
                        )
                    ))
                }
            }

            let total = FormatUtils.intValue(songResult["totalCount"])
            let allPage = max(1, Int(ceil(Double(total) / Double(max(1, limit)))))
            return MusicSearchPage(list: list, page: page, allPage: allPage, limit: limit, total: total, source: .mg)
        }
    }

    func getHotSearch() async throws -> [String] {
        let resp = try await HTTPClient.shared.get("http://jadeite.migu.cn:7090/music_search/v3/search/hotword")
        let body = try resp.jsonDictionary()
        guard resp.statusCode == 200, (body["code"] as? String) == "000000",
              let data = body["data"] as? [String: Any],
              let hotwords = data["hotwords"] as? [[String: Any]],
              let first = hotwords.first,
              let list = first["hotwordList"] as? [[String: Any]] else {
            throw MusicSDKError.apiError("获取咪咕热搜词失败")
        }
        return list.filter { FormatUtils.stringValue($0["resourceType"]) == "song" }
            .compactMap { $0["word"] as? String }
    }

    func getTipSearch(query: String) async throws -> [String] {
        let url = "https://music.migu.cn/v3/api/search/suggest?keyword=\(FormatUtils.urlEncodeComponent(query))"
        let data = try await mgFetch(url, headers: ["referer": "https://music.migu.cn/v3"])
        let songs = (data["songs"] as? [[String: Any]]) ?? []
        return songs.map { "\(FormatUtils.stringValue($0["name"])) - \(FormatUtils.stringValue($0["singerName"]))" }
    }

    // MARK: - MusicInfo (`mg/musicInfo.js`)

    func fetchMusicInfo(songId: String) async throws -> MusicInfo {
        let data = try await mgFetch(
            "https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=2",
            method: "POST",
            form: ["resourceId": songId]
        )
        guard let resources = data["resource"] as? [[String: Any]],
              let first = parseResourceInfoList(resources).first else {
            throw MusicSDKError.apiError("MG resource info not found")
        }
        return first
    }

    private func parseResourceInfoList(_ rawList: [[String: Any]]) -> [MusicInfo] {
        var ids = Set<String>()
        var result: [MusicInfo] = []
        for item in rawList {
            let songId = FormatUtils.stringValue(item["songId"])
            guard !songId.isEmpty, ids.insert(songId).inserted else { continue }

            var types: [MusicQualityItem] = []
            var map: [String: MusicQualityMeta] = [:]
            if let formats = item["newRateFormats"] as? [[String: Any]] {
                for f in formats {
                    let ft = FormatUtils.stringValue(f["formatType"])
                    let rawSize = FormatUtils.int64Value(f["size"] ?? f["androidSize"])
                    let size = rawSize > 0 ? FormatUtils.sizeFormate(rawSize) : nil
                    let q: AudioQuality
                    switch ft {
                    case "PQ": q = .k128
                    case "HQ": q = .k320
                    case "SQ": q = .flac
                    case "ZQ", "ZQ24": q = .flac24bit
                    default: continue
                    }
                    types.append(MusicQualityItem(type: q, size: size))
                    map[q.rawValue] = MusicQualityMeta(size: size)
                }
            }

            let lengthStr = FormatUtils.stringValue(item["length"])
            let interval = RegexHelper.firstMatch(#"(\d\d:\d\d)$"#, in: lengthStr)?[1]
            let imgs = item["albumImgs"] as? [[String: Any]]
            let img = imgs?.first?["img"] as? String
            let artists = item["artists"] as? [[String: Any]]

            result.append(MusicInfo(
                id: "mg_\(songId)",
                name: FormatUtils.decodeName(item["songName"] as? String),
                singer: FormatUtils.formatSingerName(artists, nameKey: "name"),
                source: .mg,
                interval: interval,
                meta: MusicMeta(
                    songId: songId,
                    albumName: FormatUtils.decodeName(item["album"] as? String),
                    picUrl: img,
                    albumId: FormatUtils.stringValue(item["albumId"]),
                    qualitys: types,
                    _qualitys: map,
                    copyrightId: FormatUtils.stringValue(item["copyrightId"]),
                    lrcUrl: item["lrcUrl"] as? String,
                    mrcUrl: item["mrcUrl"] as? String,
                    trcUrl: item["trcUrl"] as? String
                )
            ))
        }
        return result
    }

    private func parsePlaylistV5List(_ rawList: [[String: Any]]) -> [MusicInfo] {
        var ids = Set<String>()
        var result: [MusicInfo] = []
        for item in rawList {
            let songId = FormatUtils.stringValue(item["songId"])
            guard !songId.isEmpty, ids.insert(songId).inserted else { continue }

            var types: [MusicQualityItem] = []
            var map: [String: MusicQualityMeta] = [:]
            if let formats = item["audioFormats"] as? [[String: Any]] {
                for f in formats {
                    let ft = FormatUtils.stringValue(f["formatType"])
                    let rawSize = FormatUtils.int64Value(f["size"] ?? f["androidSize"])
                    let size = rawSize > 0 ? FormatUtils.sizeFormate(rawSize) : nil
                    let q: AudioQuality
                    switch ft {
                    case "PQ": q = .k128
                    case "HQ": q = .k320
                    case "SQ": q = .flac
                    case "ZQ", "ZQ24": q = .flac24bit
                    default: continue
                    }
                    types.append(MusicQualityItem(type: q, size: size))
                    map[q.rawValue] = MusicQualityMeta(size: size)
                }
            }

            let img = (item["img3"] as? String) ?? (item["img2"] as? String) ?? (item["img1"] as? String)
            let singers = item["singerList"] as? [[String: Any]]
            result.append(MusicInfo(
                id: "mg_\(songId)",
                name: FormatUtils.decodeName(item["songName"] as? String),
                singer: FormatUtils.formatSingerName(singers, nameKey: "name"),
                source: .mg,
                interval: FormatUtils.formatPlayTime(FormatUtils.intValue(item["duration"])),
                meta: MusicMeta(
                    songId: songId,
                    albumName: FormatUtils.decodeName(item["album"] as? String),
                    picUrl: img,
                    albumId: FormatUtils.stringValue(item["albumId"]),
                    qualitys: types,
                    _qualitys: map,
                    copyrightId: FormatUtils.stringValue(item["copyrightId"]),
                    lrcUrl: item["lrcUrl"] as? String,
                    mrcUrl: item["mrcUrl"] as? String,
                    trcUrl: item["trcUrl"] as? String
                )
            ))
        }
        return result
    }

    // MARK: - Leaderboard (`mg/leaderboard.js`)

    func getLeaderboardTracks(bangId: String, page: Int) async throws -> LeaderboardPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let url = "https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/querycontentbyId.do?columnId=\(bangId)&needAll=0"
            let resp = try await HTTPClient.shared.get(url)
            let body = try resp.jsonDictionary()
            guard resp.statusCode == 200, (body["code"] as? String) == "000000",
                  let columnInfo = body["columnInfo"] as? [String: Any],
                  let contents = columnInfo["contents"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("MG leaderboard failed")
            }
            let rawObjects = contents.compactMap { $0["objectInfo"] as? [String: Any] }
            let list = self.parseResourceInfoList(rawObjects)
            return LeaderboardPage(list: list, page: page, limit: 200, total: list.count, source: .mg)
        }
    }

    // MARK: - SongList (`mg/songList.js`)

    func getSongListTags() async throws -> SongListTagsResult {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let url = "https://app.c.nf.migu.cn/pc/v1.0/template/musiclistplaza-taglist/release"
            let resp = try await HTTPClient.shared.get(url, headers: Self.mobileHeaders)
            let body = try resp.jsonDictionary()
            guard (body["code"] as? String) == "000000",
                  let rawList = body["data"] as? [[String: Any]], !rawList.isEmpty else {
                throw MusicSDKError.apiError("MG getTags failed")
            }

            let hotContent = (rawList[0]["content"] as? [[String: Any]]) ?? []
            let hotTag = hotContent.compactMap { entry -> SongListTagItem? in
                guard let texts = entry["texts"] as? [String], texts.count >= 2 else { return nil }
                return SongListTagItem(id: texts[1], name: texts[0], source: .mg)
            }

            let groups = rawList.dropFirst().map { section -> SongListTagGroup in
                let header = (section["header"] as? [String: Any]) ?? [:]
                let title = FormatUtils.stringValue(header["title"])
                let content = (section["content"] as? [[String: Any]]) ?? []
                let items = content.compactMap { entry -> SongListTagItem? in
                    guard let texts = entry["texts"] as? [String], texts.count >= 2 else { return nil }
                    return SongListTagItem(id: texts[1], name: texts[0], parentName: title, source: .mg)
                }
                return SongListTagGroup(name: title, list: items)
            }
            return SongListTagsResult(hotTag: hotTag, tags: groups, source: .mg)
        }
    }

    func getSongList(sortId: String, tagId: String?, page: Int) async throws -> SongListSearchPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let url: String
            if let tagId, !tagId.isEmpty {
                url = "https://app.c.nf.migu.cn/pc/v1.0/template/musiclistplaza-listbytag/release?pageNumber=\(page)&templateVersion=2&tagId=\(tagId)"
            } else {
                url = "https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square-recommend/v1.0?templateVersion=2&pageNo=\(page)"
            }
            let resp = try await HTTPClient.shared.get(url, headers: Self.mobileHeaders)
            let body = try resp.jsonDictionary()
            guard (body["code"] as? String) == "000000",
                  let data = body["data"] as? [String: Any] else {
                throw MusicSDKError.apiError("MG getSongList failed")
            }

            var list: [OnlineSongListItem] = []
            if let contents = data["contents"] as? [[String: Any]] {
                var seen = Set<String>()
                func walk(_ arr: [[String: Any]]) {
                    for item in arr {
                        if let nested = item["contents"] as? [[String: Any]] {
                            walk(nested)
                        } else if FormatUtils.stringValue(item["resType"]) == "2021" {
                            let resId = FormatUtils.stringValue(item["resId"])
                            if !resId.isEmpty && seen.insert(resId).inserted {
                                list.append(OnlineSongListItem(
                                    id: resId,
                                    name: FormatUtils.decodeName(item["txt"] as? String),
                                    author: "",
                                    img: item["img"] as? String,
                                    playCount: nil,
                                    desc: FormatUtils.decodeName(item["txt2"] as? String),
                                    source: .mg
                                ))
                            }
                        }
                    }
                }
                walk(contents)
            } else if let contentItems = data["contentItemList"] as? [[String: Any]], contentItems.count > 1,
                      let itemList = contentItems[1]["itemList"] as? [[String: Any]] {
                for item in itemList {
                    let logEvent = (item["logEvent"] as? [String: Any]) ?? [:]
                    let barList = (item["barList"] as? [[String: Any]]) ?? []
                    list.append(OnlineSongListItem(
                        id: FormatUtils.stringValue(logEvent["contentId"]),
                        name: FormatUtils.decodeName(item["title"] as? String),
                        author: "",
                        img: item["imageUrl"] as? String,
                        playCount: barList.first?["title"] as? String,
                        desc: "",
                        source: .mg
                    ))
                }
            }
            return SongListSearchPage(list: list, page: page, limit: 30, total: 99999, source: .mg)
        }
    }

    func searchSongList(query: String, page: Int, limit: Int = 20) async throws -> SongListSearchPage {
        let encoded = FormatUtils.urlEncodeComponent(query)
        let url = "https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=1&isCopyright=1&searchSwitch=%7B%22song%22%3A0%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A0%2C%22mvSong%22%3A0%2C%22bestShow%22%3A0%2C%22songlist%22%3A1%2C%22lyricSong%22%3A0%7D&pageSize=\(limit)&text=\(encoded)&pageNo=\(page)&sort=0&sid=USS"
        let body = try await mgFetch(url, headers: searchHeaders(for: query))
        let slData = (body["songListResultData"] as? [String: Any]) ?? [:]
        let rawList = (slData["result"] as? [[String: Any]]) ?? []
        let list: [OnlineSongListItem] = rawList.compactMap { item in
            let id = FormatUtils.stringValue(item["id"])
            guard !id.isEmpty else { return nil }
            return OnlineSongListItem(
                id: id,
                name: FormatUtils.decodeName(item["name"] as? String),
                author: FormatUtils.decodeName(item["userName"] as? String),
                img: item["musicListPicUrl"] as? String,
                playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(item["playNum"])),
                desc: nil,
                total: FormatUtils.intValue(item["musicNum"]),
                source: .mg
            )
        }
        return SongListSearchPage(list: list, page: page, limit: limit, total: FormatUtils.intValue(slData["totalCount"]), source: .mg)
    }

    private func resolveSongListId(_ raw: String, depth: Int = 0) async throws -> String {
        guard depth <= 3 else { throw MusicSDKError.parseError("咪咕歌单链接解析失败") }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if RegexHelper.test(#"/playlist[/?]"#, in: trimmed) {
            if let m = RegexHelper.firstMatch(#"(?:playlistId|id)=(\d+)"#, in: trimmed), m.count >= 2 { return m[1] }
            if let m = RegexHelper.firstMatch(#"/playlist/(\d+)"#, in: trimmed), m.count >= 2 { return m[1] }
        }
        if !RegexHelper.test(#"[?&:/]"#, in: trimmed) {
            return trimmed
        }
        let resp = try await HTTPClient.shared.get(
            trimmed,
            headers: [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 9_1 like Mac OS X) AppleWebKit/601.1.46 (KHTML, like Gecko) Version/9.0 Mobile/13B143 Safari/601.1",
                "Referer": trimmed,
            ],
            followRedirects: false
        )
        if let loc = resp.header("location"), !loc.isEmpty {
            return try await resolveSongListId(loc, depth: depth + 1)
        }
        throw MusicSDKError.parseError("无法解析咪咕歌单 ID")
    }

    func getSongListDetail(idOrUrl: String, page: Int) async throws -> SongListDetailPage {
        let id = try await resolveSongListId(idOrUrl)

        async let songsData = mgFetch(
            "https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0?pageNo=\(page)&pageSize=50&playlistId=\(id)",
            headers: Self.mobileHeaders
        )
        async let infoData = mgFetch(
            "https://c.musicapp.migu.cn/MIGUM3.0/resource/playlist/v2.0?playlistId=\(id)",
            headers: Self.mobileHeaders
        )

        let (songsDict, infoDict) = try await (songsData, infoData)
        let rawList = (songsDict["songList"] as? [[String: Any]]) ?? []
        let list = parsePlaylistV5List(rawList)
        let imgItem = (infoDict["imgItem"] as? [String: Any]) ?? [:]
        let opNum = (infoDict["opNumItem"] as? [String: Any]) ?? [:]

        let info = OnlineSongListInfo(
            name: FormatUtils.decodeName(infoDict["title"] as? String),
            img: imgItem["img"] as? String,
            desc: FormatUtils.decodeName(infoDict["summary"] as? String),
            author: FormatUtils.decodeName(infoDict["ownerName"] as? String),
            playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(opNum["playNum"]))
        )
        return SongListDetailPage(list: list, page: page, limit: 50, total: FormatUtils.intValue(songsDict["totalCount"]), source: .mg, info: info)
    }

    // MARK: - Pic (`mg/pic.js`)

    func getPic(musicInfo: MusicInfo) async throws -> String {
        if let pic = musicInfo.meta.picUrl, !pic.isEmpty { return pic }
        let full = try await fetchMusicInfo(songId: musicInfo.meta.songId)
        guard let pic = full.meta.picUrl, !pic.isEmpty else {
            throw MusicSDKError.picNotFound
        }
        return pic
    }

    // MARK: - Lyric (`mg/lyric.js` + `mg/utils/mrc.js`)

    private func fetchLyricText(url: String) async throws -> String {
        let headers = [
            "Referer": "https://app.c.nf.migu.cn/",
            "User-Agent": "Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Mobile Safari/537.36",
            "channel": "0146921",
        ]
        return try await HTTPClient.withRetry(maxAttempts: 4) {
            let resp = try await HTTPClient.shared.get(url, headers: headers)
            if resp.statusCode == 200 { return resp.text }
            throw MusicSDKError.lyricNotFound
        }
    }

    func getLyric(musicInfo: MusicInfo) async throws -> LyricInfo {
        let info: MusicInfo
        if musicInfo.meta.mrcUrl == nil && musicInfo.meta.lrcUrl == nil {
            info = try await fetchMusicInfo(songId: musicInfo.meta.songId)
        } else {
            info = musicInfo
        }

        async let tlyricTask: String = {
            guard let trcUrl = info.meta.trcUrl, !trcUrl.isEmpty else { return "" }
            return (try? await self.fetchLyricText(url: trcUrl)) ?? ""
        }()

        let mainResult: (lyric: String, lxlyric: String)
        if let mrcUrl = info.meta.mrcUrl, !mrcUrl.isEmpty {
            let encrypted = try await fetchLyricText(url: mrcUrl)
            let decrypted = MGMRCDecoder.decrypt(encrypted)
            mainResult = Self.parseMRCLyric(decrypted)
        } else if let lrcUrl = info.meta.lrcUrl, !lrcUrl.isEmpty {
            let plain = try await fetchLyricText(url: lrcUrl)
            mainResult = (plain, "")
        } else {
            throw MusicSDKError.lyricNotFound
        }

        let tlyric = await tlyricTask
        guard !mainResult.lyric.isEmpty else { throw MusicSDKError.lyricNotFound }
        return LyricInfo(lyric: mainResult.lyric, tlyric: tlyric, lxlyric: mainResult.lxlyric)
    }

    static func parseMRCLyric(_ raw: String) -> (lyric: String, lxlyric: String) {
        let cleaned = raw.replacingOccurrences(of: "\r", with: "")
        var lrcLines: [String] = []
        var lxLines: [String] = []

        for line in cleaned.components(separatedBy: "\n") {
            guard line.count >= 6,
                  let m = RegexHelper.firstMatch(#"^\s*\[(\d+),\d+\]"#, in: line),
                  m.count >= 2, let startMs = Int(m[1]) else {
                continue
            }
            let ms = String(format: "%03d", startMs % 1000)
            let sec = startMs / 1000
            let mm = String(format: "%02d", sec / 60)
            let ss = String(format: "%02d", sec % 60)
            let tag = "[\(mm):\(ss).\(ms)]"

            let words = String(line.dropFirst(m[0].count))
            let plain = RegexHelper.replace(#"\(\d+,\d+\)"#, in: words, with: "")
            lrcLines.append("\(tag)\(plain)")

            let wordMatches = RegexHelper.allMatches(#"\((\d+),(\d+)\)"#, in: words)
            guard !wordMatches.isEmpty else { continue }
            guard let regex = try? NSRegularExpression(pattern: #"\(\d+,\d+\)"#) else { continue }
            let ns = words as NSString
            let matches = regex.matches(in: words, range: NSRange(location: 0, length: ns.length))
            var parts: [String] = []
            var cursor = 0
            for match in matches {
                parts.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                cursor = match.range.location + match.range.length
            }

            var built = ""
            for (idx, wm) in wordMatches.enumerated() where wm.count >= 3 {
                let relStart = (Int(wm[1]) ?? startMs) - startMs
                let dur = Int(wm[2]) ?? 0
                let chunk = idx < parts.count ? parts[idx] : ""
                built += "<\(max(relStart, 0)),\(dur)>\(chunk)"
            }
            lxLines.append("\(tag)\(built)")
        }
        return (lrcLines.joined(separator: "\n"), lxLines.joined(separator: "\n"))
    }
}
