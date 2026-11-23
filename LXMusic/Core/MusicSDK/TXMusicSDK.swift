import Foundation

/// Native Swift port of Tencent QQ Music SDK (`src/renderer/utils/musicSdk/tx/`).
final class TXMusicSDK: MusicSDK, @unchecked Sendable {
    let source: MusicSource = .tx

    let songListSortOptions: [SongListSortOption] = [
        SongListSortOption(id: "-1", name: "推荐"),
        SongListSortOption(id: "3", name: "最热"),
        SongListSortOption(id: "2", name: "最新"),
    ]

    let leaderboardBoards: [LeaderboardBoard] = [
        ("4", "流行指数榜"), ("26", "热歌榜"), ("27", "新歌榜"), ("62", "飙升榜"),
        ("58", "说唱榜"), ("57", "喜力电音榜"), ("28", "网络歌曲榜"), ("5", "内地榜"),
        ("3", "欧美榜"), ("59", "香港地区榜"), ("16", "韩国榜"), ("60", "抖快榜"),
        ("29", "影视金曲榜"), ("17", "日本榜"), ("52", "腾讯音乐人原创榜"), ("36", "K歌金曲榜"),
        ("61", "台湾地区榜"), ("63", "DJ舞曲榜"), ("64", "综艺新歌榜"), ("65", "国风热歌榜"),
        ("67", "听歌识曲榜"), ("72", "动漫音乐榜"), ("73", "游戏音乐榜"), ("75", "有声榜"),
        ("131", "校园音乐人排行榜"),
    ].map { LeaderboardBoard(id: "tx__\($0.0)", name: $0.1, bangid: $0.0, source: .tx) }

    private let lock = NSLock()
    private var cachedPeriods: [String: String] = [:]
    private var cachedSongIds: [String: Int64] = [:]

    // MARK: - `zzcSign` (`tx/utils/crypto.js`)

    private static let part1Indexes = [23, 14, 6, 36, 16, 40, 7, 19]
    private static let part2Indexes = [16, 1, 32, 12, 19, 27, 8, 5]
    private static let scrambleValues: [UInt8] = [
        89, 39, 179, 150, 218, 82, 58, 252, 177, 52,
        186, 123, 120, 64, 242, 133, 143, 161, 121, 179,
    ]

    static func zzcSign(_ text: String) -> String {
        let digest = CryptoUtils.sha1(Data(text.utf8))
        let digestBytes = [UInt8](digest)
        let hashChars = Array(digest.hexLowercased)

        // Safely skips index 40 (out of bounds on 40-char SHA-1 hex, matching JS `hash[40] === undefined`).
        let part1 = String(part1Indexes.compactMap { $0 < hashChars.count ? hashChars[$0] : nil })
        let part2 = String(part2Indexes.compactMap { $0 < hashChars.count ? hashChars[$0] : nil })

        var part3Bytes = [UInt8](repeating: 0, count: 20)
        for i in 0..<20 {
            part3Bytes[i] = scrambleValues[i] ^ digestBytes[i]
        }
        let b64Part = Data(part3Bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "=", with: "")

        return "zzc\(part1)\(b64Part)\(part2)".lowercased()
    }

    private func signRequest(_ data: [String: Any]) async throws -> HTTPResponse {
        let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        let sign = Self.zzcSign(jsonString)
        let url = "https://u.y.qq.com/cgi-bin/musics.fcg?sign=\(sign)"
        return try await HTTPClient.shared.request(
            url,
            method: "POST",
            headers: ["User-Agent": "QQMusic 14090508(android 12)"],
            body: .jsonString(jsonString)
        )
    }

    // MARK: - Track Mapping Helper

    private func mapSongItem(_ item: [String: Any], checkAlbumNameForPic: Bool) -> MusicInfo? {
        guard let file = item["file"] as? [String: Any],
              let mediaMid = file["media_mid"] as? String, !mediaMid.isEmpty else {
            return nil
        }

        var types: [MusicQualityItem] = []
        var map: [String: MusicQualityMeta] = [:]
        let s128 = FormatUtils.int64Value(file["size_128mp3"])
        if s128 > 0 {
            let s = FormatUtils.sizeFormate(s128)
            types.append(MusicQualityItem(type: .k128, size: s))
            map[AudioQuality.k128.rawValue] = MusicQualityMeta(size: s)
        }
        let s320 = FormatUtils.int64Value(file["size_320mp3"])
        if s320 > 0 {
            let s = FormatUtils.sizeFormate(s320)
            types.append(MusicQualityItem(type: .k320, size: s))
            map[AudioQuality.k320.rawValue] = MusicQualityMeta(size: s)
        }
        let sFlac = FormatUtils.int64Value(file["size_flac"])
        if sFlac > 0 {
            let s = FormatUtils.sizeFormate(sFlac)
            types.append(MusicQualityItem(type: .flac, size: s))
            map[AudioQuality.flac.rawValue] = MusicQualityMeta(size: s)
        }
        let sHires = FormatUtils.int64Value(file["size_hires"])
        if sHires > 0 {
            let s = FormatUtils.sizeFormate(sHires)
            types.append(MusicQualityItem(type: .flac24bit, size: s))
            map[AudioQuality.flac24bit.rawValue] = MusicQualityMeta(size: s)
        }

        let album = (item["album"] as? [String: Any]) ?? [:]
        let albumName = FormatUtils.stringValue(album["name"])
        let albumMid = FormatUtils.stringValue(album["mid"])
        let singers = item["singer"] as? [[String: Any]] ?? []
        let singerStr = FormatUtils.formatSingerName(singers, nameKey: "name")

        let isEmptyAlbum = checkAlbumNameForPic
            ? (albumName.isEmpty || albumName == "空" || albumMid.isEmpty)
            : (albumMid.isEmpty || albumMid == "空")

        let picUrl: String?
        if isEmptyAlbum {
            if let firstSingerMid = singers.first?["mid"] as? String, !firstSingerMid.isEmpty {
                picUrl = "https://y.gtimg.cn/music/photo_new/T001R500x500M000\(firstSingerMid).jpg"
            } else {
                picUrl = nil
            }
        } else {
            picUrl = "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(albumMid).jpg"
        }

        let songmid = FormatUtils.stringValue(item["mid"])
        guard !songmid.isEmpty else { return nil }
        let numericId = FormatUtils.int64Value(item["id"])
        let duration = FormatUtils.intValue(item["interval"])
        let interval = duration > 0 ? FormatUtils.formatPlayTime(duration) : nil

        return MusicInfo(
            id: "tx_\(songmid)",
            name: FormatUtils.decodeName(item["title"] as? String ?? item["name"] as? String),
            singer: singerStr,
            source: .tx,
            interval: interval,
            meta: MusicMeta(
                songId: songmid,
                albumName: FormatUtils.decodeName(albumName),
                picUrl: picUrl,
                albumId: albumMid,
                qualitys: types,
                _qualitys: map,
                strMediaMid: mediaMid,
                id: numericId > 0 ? numericId : nil,
                albumMid: albumMid
            )
        )
    }

    // MARK: - Search (`tx/musicSearch.js`)

    private func generateSearchId() -> String {
        let hex = CryptoUtils.randomBytes(16).hexUppercased
        let tail = String(format: "%05d", Int.random(in: 0..<100_000))
        return hex + tail
    }

    func searchMusic(query: String, page: Int, limit: Int = 50) async throws -> MusicSearchPage {
        try await HTTPClient.withRetry(maxAttempts: 4) {
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
                        "searchid": self.generateSearchId(),
                    ],
                ],
            ]

            let resp = try await self.signRequest(payload)
            let body = try resp.jsonDictionary()
            let req = (body["music.search.SearchCgiService"] as? [String: Any]) ?? (body["req"] as? [String: Any])
            guard FormatUtils.intValue(body["code"]) == 0,
                  let req, FormatUtils.intValue(req["code"]) == 0,
                  let data = req["data"] as? [String: Any],
                  let bodyObj = data["body"] as? [String: Any],
                  let songObj = bodyObj["song"] as? [String: Any],
                  let rawList = songObj["list"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("TX search failed")
            }

            let list = rawList.compactMap { self.mapSongItem($0, checkAlbumNameForPic: false) }
            let meta = (data["meta"] as? [String: Any]) ?? [:]
            let total = FormatUtils.intValue(meta["sum"])
            let allPage = max(1, Int(ceil(Double(total) / Double(max(1, limit)))))
            return MusicSearchPage(list: list, page: page, allPage: allPage, limit: limit, total: total, source: .tx)
        }
    }

    func getHotSearch() async throws -> [String] {
        let payload: [String: Any] = [
            "comm": [
                "ct": "19", "cv": "1803", "guid": "0", "patch": "118",
                "psrf_access_token_expiresAt": 0, "psrf_qqaccess_token": "",
                "psrf_qqopenid": "", "psrf_qqunionid": "",
                "tmeAppID": "qqmusic", "tmeLoginType": 0, "uin": "0", "wid": "0",
            ],
            "hotkey": [
                "method": "GetHotkeyForQQMusicPC",
                "module": "tencent_musicsoso_hotkey.HotkeyService",
                "param": ["search_id": "", "uin": 0],
            ],
        ]
        let resp = try await HTTPClient.shared.postJSON(
            "https://u.y.qq.com/cgi-bin/musicu.fcg",
            json: payload,
            headers: ["Referer": "https://y.qq.com/portal/player.html"]
        )
        let body = try resp.jsonDictionary()
        guard resp.statusCode == 200, FormatUtils.intValue(body["code"]) == 0,
              let hotkey = body["hotkey"] as? [String: Any],
              let data = hotkey["data"] as? [String: Any],
              let vec = data["vec_hotkey"] as? [[String: Any]] else {
            throw MusicSDKError.apiError("获取QQ音乐热搜词失败")
        }
        return vec.compactMap { $0["query"] as? String }
    }

    func getTipSearch(query: String) async throws -> [String] {
        let url = "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?is_xml=0&format=json&key=\(FormatUtils.urlEncodeComponent(query))&loginUin=0&hostUin=0&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq&needNewCode=0"
        let resp = try await HTTPClient.shared.get(url, headers: ["Referer": "https://y.qq.com/portal/player.html"])
        let body = try resp.jsonDictionary()
        guard resp.statusCode == 200, FormatUtils.intValue(body["code"]) == 0,
              let data = body["data"] as? [String: Any],
              let song = data["song"] as? [String: Any],
              let items = song["itemlist"] as? [[String: Any]] else {
            return []
        }
        return items.map { "\(FormatUtils.stringValue($0["name"])) - \(FormatUtils.stringValue($0["singer"]))" }
    }

    // MARK: - Leaderboard (`tx/leaderboard.js`)

    private func fetchPeriod(for bangId: String) async -> String? {
        if let existing = lock.withLock({ cachedPeriods[bangId] }) {
            return existing
        }

        guard let resp = try? await HTTPClient.shared.get("https://c.y.qq.com/node/pc/wk_v15/top.html") else {
            return nil
        }
        let html = resp.text
        let matches = RegexHelper.allMatches(
            #"data-listname="(.+?)" data-tid=".*?/(.+?)" data-date="(.+?)""#,
            in: html
        )
        return lock.withLock {
            for m in matches where m.count >= 4 {
                cachedPeriods[m[2]] = m[3]
            }
            return cachedPeriods[bangId]
        }
    }

    func getLeaderboardTracks(bangId: String, page: Int) async throws -> LeaderboardPage {
        let period = await fetchPeriod(for: bangId)
        return try await HTTPClient.withRetry(maxAttempts: 3) {
            var param: [String: Any] = [
                "topid": Int(bangId) ?? 26,
                "num": 300,
            ]
            if let period, !period.isEmpty {
                param["period"] = period
            }
            let payload: [String: Any] = [
                "toplist": [
                    "module": "musicToplist.ToplistInfoServer",
                    "method": "GetDetail",
                    "param": param,
                ],
                "comm": ["uin": 0, "format": "json", "ct": 20, "cv": 1859],
            ]
            let resp = try await HTTPClient.shared.postJSON(
                "https://u.y.qq.com/cgi-bin/musicu.fcg",
                json: payload,
                headers: ["User-Agent": "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)"]
            )
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["code"]) == 0,
                  let toplist = body["toplist"] as? [String: Any],
                  let data = toplist["data"] as? [String: Any],
                  let rawList = data["songInfoList"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("TX leaderboard failed")
            }
            let list = rawList.compactMap { self.mapSongItem($0, checkAlbumNameForPic: true) }
            return LeaderboardPage(list: list, page: 1, limit: 300, total: list.count, source: .tx)
        }
    }

    // MARK: - SongList (`tx/songList.js`)

    func getSongListTags() async throws -> SongListTagsResult {
        async let groupsTask = fetchTXTagGroups()
        async let hotTask = fetchTXHotTags()
        let (groups, hot) = try await (groupsTask, hotTask)
        return SongListTagsResult(hotTag: hot, tags: groups, source: .tx)
    }

    private func fetchTXTagGroups() async throws -> [SongListTagGroup] {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let url = "https://u.y.qq.com/cgi-bin/musicu.fcg?loginUin=0&hostUin=0&format=json&inCharset=utf-8&outCharset=utf-8&notice=0&platform=wk_v15.json&needNewCode=0&data=%7B%22tags%22%3A%7B%22method%22%3A%22get_all_categories%22%2C%22param%22%3A%7B%22qq%22%3A%22%22%7D%2C%22module%22%3A%22playlist.PlaylistAllCategoriesServer%22%7D%7D"
            let resp = try await HTTPClient.shared.get(url)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["code"]) == 0,
                  let tags = body["tags"] as? [String: Any],
                  let data = tags["data"] as? [String: Any],
                  let vGroup = data["v_group"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("TX getTags failed")
            }
            return vGroup.map { group in
                let gName = FormatUtils.stringValue(group["group_name"])
                let gId = FormatUtils.stringValue(group["group_id"])
                let items = (group["v_item"] as? [[String: Any]]) ?? []
                return SongListTagGroup(
                    name: gName,
                    list: items.map { item in
                        SongListTagItem(
                            id: FormatUtils.stringValue(item["id"]),
                            name: FormatUtils.stringValue(item["name"]),
                            parentId: gId,
                            parentName: gName,
                            source: .tx
                        )
                    }
                )
            }
        }
    }

    private func fetchTXHotTags() async throws -> [SongListTagItem] {
        guard let resp = try? await HTTPClient.shared.get("https://c.y.qq.com/node/pc/wk_v15/category_playlist.html"),
              resp.statusCode == 200 else {
            return []
        }
        let html = resp.text
        let matches = RegexHelper.allMatches(#"class="c_bg_link js_tag_item" data-id="(\w+)">(.+?)</a>"#, in: html)
        return matches.compactMap { m in
            guard m.count >= 3 else { return nil }
            return SongListTagItem(id: m[1], name: FormatUtils.decodeName(m[2]), source: .tx)
        }
    }

    func getSongList(sortId: String, tagId: String?, page: Int) async throws -> SongListSearchPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let limit = 36
            if (tagId == nil || tagId?.isEmpty == true) && sortId == "-1" {
                let dataDict: [String: Any] = [
                    "comm": ["cv": 1602, "ct": 20],
                    "playlist": [
                        "module": "music.playlist.PlaylistSquare",
                        "method": "GetRecommendWhole",
                        "param": [
                            "IsReqFeed": true,
                            "FeedReq": ["From": (page - 1) * limit, "Size": limit],
                        ],
                    ],
                ]
                let dataStr = String(data: try JSONSerialization.data(withJSONObject: dataDict), encoding: .utf8) ?? "{}"
                let url = "https://u.y.qq.com/cgi-bin/musicu.fcg?loginUin=0&hostUin=0&format=json&inCharset=utf-8&outCharset=utf-8&notice=0&platform=wk_v15.json&needNewCode=0&data=\(FormatUtils.urlEncodeComponent(dataStr))"
                let resp = try await HTTPClient.shared.get(url)
                let body = try resp.jsonDictionary()
                guard FormatUtils.intValue(body["code"]) == 0,
                      let playlist = body["playlist"] as? [String: Any],
                      let data = playlist["data"] as? [String: Any],
                      let feedRsp = data["FeedRsp"] as? [String: Any],
                      let rawList = feedRsp["List"] as? [[String: Any]] else {
                    throw MusicSDKError.apiError("TX recommend songlist failed")
                }

                let list: [OnlineSongListItem] = rawList.compactMap { entry in
                    guard let pl = entry["Playlist"] as? [String: Any],
                          let basic = pl["basic"] as? [String: Any] else { return nil }
                    let creator = (basic["creator"] as? [String: Any]) ?? [:]
                    let cover = (basic["cover"] as? [String: Any]) ?? [:]
                    let med = FormatUtils.stringValue(cover["medium_url"])
                    let img = med.isEmpty ? FormatUtils.stringValue(cover["default_url"]) : med
                    let modTime = FormatUtils.int64Value(basic["modify_time"])
                    let rawDesc = FormatUtils.decodeName(basic["desc"] as? String).replacingOccurrences(of: "<br>", with: "\n")
                    return OnlineSongListItem(
                        id: FormatUtils.stringValue(basic["tid"]),
                        name: FormatUtils.decodeName(basic["title"] as? String),
                        author: FormatUtils.decodeName(creator["nick"] as? String),
                        img: img.isEmpty ? nil : img,
                        playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(basic["play_cnt"])),
                        desc: rawDesc,
                        total: FormatUtils.intValue(basic["song_cnt"]),
                        time: modTime > 0 ? FormatUtils.formatDateYMD(milliseconds: modTime * 1000) : nil,
                        source: .tx
                    )
                }
                let total = FormatUtils.intValue(feedRsp["FromLimit"])
                return SongListSearchPage(list: list, page: page, limit: limit, total: total, source: .tx)
            } else {
                let effectiveTag = Int((tagId?.isEmpty == false ? tagId! : sortId)) ?? 3
                let dataDict: [String: Any] = [
                    "comm": ["cv": 1602, "ct": 20],
                    "playlist": [
                        "method": "get_category_content",
                        "param": [
                            "titleid": effectiveTag,
                            "caller": "0",
                            "category_id": effectiveTag,
                            "size": limit,
                            "page": max(0, page - 1),
                            "use_page": 1,
                        ],
                        "module": "playlist.PlayListCategoryServer",
                    ],
                ]
                let dataStr = String(data: try JSONSerialization.data(withJSONObject: dataDict), encoding: .utf8) ?? "{}"
                let url = "https://u.y.qq.com/cgi-bin/musicu.fcg?loginUin=0&hostUin=0&format=json&inCharset=utf-8&outCharset=utf-8&notice=0&platform=wk_v15.json&needNewCode=0&data=\(FormatUtils.urlEncodeComponent(dataStr))"
                let resp = try await HTTPClient.shared.get(url)
                let body = try resp.jsonDictionary()
                guard FormatUtils.intValue(body["code"]) == 0,
                      let playlist = body["playlist"] as? [String: Any],
                      let data = playlist["data"] as? [String: Any],
                      let content = data["content"] as? [String: Any],
                      let vItem = content["v_item"] as? [[String: Any]] else {
                    throw MusicSDKError.apiError("TX category songlist failed")
                }

                let list: [OnlineSongListItem] = vItem.compactMap { entry in
                    guard let basic = entry["basic"] as? [String: Any] else { return nil }
                    let creator = (basic["creator"] as? [String: Any]) ?? [:]
                    let cover = (basic["cover"] as? [String: Any]) ?? [:]
                    let med = FormatUtils.stringValue(cover["medium_url"])
                    let img = med.isEmpty ? FormatUtils.stringValue(cover["default_url"]) : med
                    return OnlineSongListItem(
                        id: FormatUtils.stringValue(basic["tid"]),
                        name: FormatUtils.decodeName(basic["title"] as? String),
                        author: FormatUtils.decodeName(creator["nick"] as? String),
                        img: img.isEmpty ? nil : img,
                        playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(basic["play_cnt"])),
                        desc: FormatUtils.decodeName(basic["desc"] as? String).replacingOccurrences(of: "<br>", with: "\n"),
                        source: .tx
                    )
                }
                return SongListSearchPage(list: list, page: page, limit: limit, total: FormatUtils.intValue(content["total_cnt"]), source: .tx)
            }
        }
    }

    func searchSongList(query: String, page: Int, limit: Int = 20) async throws -> SongListSearchPage {
        try await HTTPClient.withRetry(maxAttempts: 4) {
            let url = "http://c.y.qq.com/soso/fcgi-bin/client_music_search_songlist?page_no=\(max(0, page - 1))&num_per_page=\(limit)&format=json&query=\(FormatUtils.urlEncodeComponent(query))&remoteplace=txt.yqq.playlist&inCharset=utf8&outCharset=utf-8"
            let resp = try await HTTPClient.shared.get(url, headers: [
                "User-Agent": "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)",
                "Referer": "http://y.qq.com/portal/search.html",
            ])
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["code"]) == 0,
                  let data = body["data"] as? [String: Any],
                  let rawList = data["list"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("TX searchSongList failed")
            }
            let list = rawList.map { item -> OnlineSongListItem in
                let creator = (item["creator"] as? [String: Any]) ?? [:]
                let rawIntro = FormatUtils.decodeName(FormatUtils.decodeName(item["introduction"] as? String))
                    .replacingOccurrences(of: "<br>", with: "\n")
                return OnlineSongListItem(
                    id: FormatUtils.stringValue(item["dissid"]),
                    name: FormatUtils.decodeName(item["dissname"] as? String),
                    author: FormatUtils.decodeName(creator["name"] as? String),
                    img: item["imgurl"] as? String,
                    playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(item["listennum"])),
                    desc: rawIntro,
                    total: FormatUtils.intValue(item["song_count"]),
                    time: FormatUtils.formatDateYMD(fromString: item["createtime"] as? String),
                    source: .tx
                )
            }
            return SongListSearchPage(list: list, page: page, limit: limit, total: FormatUtils.intValue(data["sum"]), source: .tx)
        }
    }

    private func resolveListId(_ raw: String) async throws -> String {
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RegexHelper.test(#"[?&:/]"#, in: id) else { return id }

        if !RegexHelper.test(#"/playlist/(\d+)"#, in: id) {
            let resp = try await HTTPClient.shared.get(id, followRedirects: false)
            if let loc = resp.header("location"), !loc.isEmpty {
                id = loc
            }
        }
        if let m = RegexHelper.firstMatch(#"/playlist/(\d+)"#, in: id), m.count >= 2 { return m[1] }
        if let m = RegexHelper.firstMatch(#"id=(\d+)"#, in: id), m.count >= 2 { return m[1] }
        throw MusicSDKError.parseError("无法解析QQ音乐歌单链接")
    }

    func getSongListDetail(idOrUrl: String, page: Int) async throws -> SongListDetailPage {
        let id = try await resolveListId(idOrUrl)
        let headers = [
            "Origin": "https://y.qq.com",
            "Referer": "https://y.qq.com/n/yqq/playsquare/\(id).html",
        ]

        // Primary API
        let url = "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=\(id)&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0"
        if let resp = try? await HTTPClient.shared.get(url, headers: headers),
           let body = try? resp.jsonDictionary(),
           FormatUtils.intValue(body["code"]) == 0,
           FormatUtils.intValue(body["subcode"]) == 0,
           let cdlist = body["cdlist"] as? [[String: Any]],
           let cd = cdlist.first,
           let rawSongs = cd["songlist"] as? [[String: Any]] {
            let list = rawSongs.compactMap { mapSongItem($0, checkAlbumNameForPic: true) }
            let info = OnlineSongListInfo(
                name: FormatUtils.decodeName(cd["dissname"] as? String),
                img: cd["logo"] as? String,
                desc: FormatUtils.decodeName(cd["desc"] as? String).replacingOccurrences(of: "<br>", with: "\n"),
                author: FormatUtils.decodeName(cd["nickname"] as? String),
                playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(cd["visitnum"]))
            )
            return SongListDetailPage(list: list, page: 1, limit: list.count + 1, total: list.count, source: .tx, info: info)
        }

        // Fallback API (`getListDetail2`)
        let payload: [String: Any] = [
            "comm": [
                "cv": 4747474, "ct": 24, "format": "json",
                "inCharset": "utf-8", "outCharset": "utf-8",
                "platform": "yqq.json", "needNewCode": 1, "uin": 0,
            ],
            "req_1": [
                "module": "music.srfDissInfo.aiDissInfo",
                "method": "uniform_get_Dissinfo",
                "param": [
                    "disstid": Int64(id) ?? 0,
                    "userinfo": 1, "tag": 1, "orderlist": 1,
                    "song_begin": 0, "song_num": 100000,
                    "onlysonglist": 0, "enc_host_uin": "",
                ],
            ],
        ]
        let resp = try await HTTPClient.shared.postJSON("https://u.y.qq.com/cgi-bin/musicu.fcg", json: payload, headers: headers)
        let body = try resp.jsonDictionary()
        guard FormatUtils.intValue(body["code"]) == 0,
              let req1 = body["req_1"] as? [String: Any],
              FormatUtils.intValue(req1["code"]) == 0,
              let data = req1["data"] as? [String: Any],
              let rawSongs = data["songlist"] as? [[String: Any]] else {
            throw MusicSDKError.apiError("获取QQ音乐歌单详情失败")
        }
        let dirinfo = (data["dirinfo"] as? [String: Any]) ?? [:]
        let list = rawSongs.compactMap { mapSongItem($0, checkAlbumNameForPic: true) }
        let info = OnlineSongListInfo(
            name: FormatUtils.decodeName(dirinfo["title"] as? String),
            img: dirinfo["picurl"] as? String,
            desc: FormatUtils.decodeName(dirinfo["desc"] as? String).replacingOccurrences(of: "<br>", with: "\n"),
            author: FormatUtils.decodeName(dirinfo["host_nick"] as? String),
            playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(dirinfo["listennum"]))
        )
        return SongListDetailPage(list: list, page: 1, limit: 100000, total: FormatUtils.intValue(data["total_song_num"]), source: .tx, info: info)
    }

    // MARK: - Pic & MusicInfo (`tx/index.js`, `tx/musicInfo.js`)

    func getPic(musicInfo: MusicInfo) async throws -> String {
        if let pic = musicInfo.meta.picUrl, !pic.isEmpty { return pic }
        let albumId = musicInfo.meta.albumMid ?? musicInfo.meta.albumId ?? ""
        guard !albumId.isEmpty else { throw MusicSDKError.picNotFound }
        return "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(albumId).jpg"
    }

    private func resolveNumericSongId(for musicInfo: MusicInfo) async throws -> Int64 {
        if let id = musicInfo.meta.id, id > 0 { return id }
        let songmid = musicInfo.meta.songId
        if let cached = lock.withLock({ cachedSongIds[songmid] }) {
            return cached
        }

        let payload: [String: Any] = [
            "comm": ["ct": "19", "cv": "1859", "uin": "0"],
            "req": [
                "module": "music.pf_song_detail_svr",
                "method": "get_song_detail_yqq",
                "param": ["song_type": 0, "song_mid": songmid],
            ],
        ]
        let resp = try await HTTPClient.shared.postJSON(
            "https://u.y.qq.com/cgi-bin/musicu.fcg",
            json: payload,
            headers: ["User-Agent": "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)"]
        )
        let body = try resp.jsonDictionary()
        guard FormatUtils.intValue(body["code"]) == 0,
              let req = body["req"] as? [String: Any],
              FormatUtils.intValue(req["code"]) == 0,
              let data = req["data"] as? [String: Any],
              let track = data["track_info"] as? [String: Any] else {
            throw MusicSDKError.lyricNotFound
        }
        let id = FormatUtils.int64Value(track["id"])
        guard id > 0 else { throw MusicSDKError.lyricNotFound }
        lock.withLock { cachedSongIds[songmid] = id }
        return id
    }

    // MARK: - Lyric (`tx/lyric.js`)

    func getLyric(musicInfo: MusicInfo) async throws -> LyricInfo {
        let numericId = try await resolveNumericSongId(for: musicInfo)
        return try await HTTPClient.withRetry(maxAttempts: 3) {
            let payload: [String: Any] = [
                "comm": ["ct": "19", "cv": "1859", "uin": "0"],
                "req": [
                    "method": "GetPlayLyricInfo",
                    "module": "music.musichallSong.PlayLyricInfo",
                    "param": [
                        "format": "json",
                        "crypt": 1,
                        "ct": 19,
                        "cv": 1873,
                        "interval": 0,
                        "lrc_t": 0,
                        "qrc": 1,
                        "qrc_t": 0,
                        "roma": 0,
                        "roma_t": 0,
                        "songID": numericId,
                        "trans": 1,
                        "trans_t": 0,
                        "type": -1,
                    ],
                ],
            ]
            let resp = try await HTTPClient.shared.postJSON(
                "https://u.y.qq.com/cgi-bin/musicu.fcg",
                json: payload,
                headers: [
                    "referer": "https://y.qq.com",
                    "user-agent": "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36",
                ]
            )
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["code"]) == 0,
                  let req = body["req"] as? [String: Any],
                  FormatUtils.intValue(req["code"]) == 0,
                  let data = req["data"] as? [String: Any] else {
                throw MusicSDKError.lyricNotFound
            }

            let rawLrc = TXQRCDecoder.decode(FormatUtils.stringValue(data["lyric"]))
            let rawTrans = TXQRCDecoder.decode(FormatUtils.stringValue(data["trans"]))
            let parsed = Self.parseQRC(lrc: rawLrc, tlrc: rawTrans)
            guard !parsed.lyric.isEmpty else { throw MusicSDKError.lyricNotFound }
            return parsed
        }
    }

    static func parseQRC(lrc: String, tlrc: String) -> LyricInfo {
        var lyric = ""
        var lxlyric = ""
        var tlyric = ""

        if !lrc.isEmpty {
            let res = parseQRCLyricBody(removeXMLTag(lrc))
            lyric = res.lyric
            lxlyric = res.lxlyric
        }
        if !tlrc.isEmpty {
            tlyric = fixTimeTags(target: tlrc, reference: lyric, pad3: true)
        }
        return LyricInfo(lyric: lyric, tlyric: tlyric, lxlyric: lxlyric)
    }

    private static func removeXMLTag(_ str: String) -> String {
        var s = RegexHelper.replace(#"^[\S\s]*?LyricContent=""#, in: str, with: "")
        s = RegexHelper.replace(#""\/>[\S\s]*?$"#, in: s, with: "")
        return s
    }

    private static func msFormat(_ timeMs: Int) -> String {
        let ms = String(format: "%03d", timeMs % 1000)
        let sec = timeMs / 1000
        let m = String(format: "%02d", sec / 60)
        let s = String(format: "%02d", sec % 60)
        return "[\(m):\(s).\(ms)]"
    }

    private static func parseQRCLyricBody(_ raw: String) -> (lyric: String, lxlyric: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r", with: "")
        var lrcLines: [String] = []
        var lxLines: [String] = []

        for rawLine in cleaned.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let m = RegexHelper.firstMatch(#"^\[(\d+),\d+\]"#, in: line), m.count >= 2, let startMs = Int(m[1]) {
                let startTag = msFormat(startMs)
                let words = String(line.dropFirst(m[0].count))
                let plainWords = RegexHelper.replace(#"\(\d+,\d+\)"#, in: words, with: "")
                lrcLines.append("\(startTag)\(plainWords)")

                let wordMatches = RegexHelper.allMatches(#"\((\d+),(\d+)\)"#, in: words)
                if !wordMatches.isEmpty {
                    let textParts = splitByPattern(words, pattern: #"\(\d+,\d+\)"#)
                    var built = ""
                    for (idx, wm) in wordMatches.enumerated() where wm.count >= 3 {
                        let wStart = max((Int(wm[1]) ?? startMs) - startMs, 0)
                        let wDur = Int(wm[2]) ?? 0
                        let chunkText = idx < textParts.count ? textParts[idx] : ""
                        built += "<\(wStart),\(wDur)>\(chunkText)"
                    }
                    lxLines.append("\(startTag)\(built)")
                }
            } else if line.hasPrefix("[offset") {
                lrcLines.append(line)
                lxLines.append(line)
            } else if RegexHelper.test(#"^\[[\d:.]+\]"#, in: line) {
                lrcLines.append(line)
            }
        }
        return (lrcLines.joined(separator: "\n"), lxLines.joined(separator: "\n"))
    }

    private static func splitByPattern(_ str: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [str] }
        let ns = str as NSString
        let matches = regex.matches(in: str, range: NSRange(location: 0, length: ns.length))
        var parts: [String] = []
        var cursor = 0
        for m in matches {
            parts.append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            cursor = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: cursor))
        return parts
    }

    private static func timestampToComparableMs(_ raw: String) -> Int {
        var str = raw
        if !str.contains(".") { str += ".0" }
        var arr = str.components(separatedBy: CharacterSet(charactersIn: ":."))
        while arr.count < 3 { arr.insert("0", at: 0) }
        let m = Int(arr[0]) ?? 0
        let s = Int(arr[1]) ?? 0
        let ms = Int(arr[2]) ?? 0
        return m * 3_600_000 + s * 1000 + ms
    }

    private static func fixTimeTags(target: String, reference: String, pad3: Bool) -> String {
        var refLines = reference.components(separatedBy: "\n")
        let targetLines = target.components(separatedBy: "\n")
        var result: [String] = []

        for line in targetLines {
            guard let m = RegexHelper.firstMatch(#"^\[([\d:.]+)\]"#, in: line), m.count >= 2 else { continue }
            let words = String(line.dropFirst(m[0].count))
            guard !words.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            var timeStr = m[1]
            if pad3, let dotIdx = timeStr.firstIndex(of: ".") {
                let fracLen = timeStr.distance(from: timeStr.index(after: dotIdx), to: timeStr.endIndex)
                if fracLen < 3 {
                    timeStr += String(repeating: "0", count: 3 - fracLen)
                }
            }
            let t1 = timestampToComparableMs(timeStr)

            var temp: [String] = []
            while !refLines.isEmpty {
                let refLine = refLines.removeFirst()
                guard let rm = RegexHelper.firstMatch(#"^\[([\d:.]+)\]"#, in: refLine), rm.count >= 2 else { continue }
                let t2 = timestampToComparableMs(rm[1])
                if abs(t1 - t2) < 100 {
                    let fixed = (rm[0] + words).trimmingCharacters(in: .whitespaces)
                    if !fixed.isEmpty { result.append(fixed) }
                    break
                }
                temp.append(refLine)
            }
            refLines = temp + refLines
        }
        return result.joined(separator: "\n")
    }
}
