import Foundation

/// Native Swift port of Kugou Music SDK (`src/renderer/utils/musicSdk/kg/` & `src/common/utils/lyricUtils/kg.js`).
final class KGMusicSDK: MusicSDK, @unchecked Sendable {
    let source: MusicSource = .kg

    let songListSortOptions: [SongListSortOption] = [
        SongListSortOption(id: "5", name: "推荐"),
        SongListSortOption(id: "6", name: "最热"),
        SongListSortOption(id: "7", name: "最新"),
        SongListSortOption(id: "3", name: "热藏"),
        SongListSortOption(id: "8", name: "飙升"),
    ]

    let leaderboardBoards: [LeaderboardBoard] = [
        ("8888", "TOP500"), ("6666", "飙升榜"), ("59703", "蜂鸟流行音乐榜"), ("52144", "抖音热歌榜"),
        ("52767", "快手热歌榜"), ("24971", "DJ热歌榜"), ("23784", "网络红歌榜"), ("44412", "说唱先锋榜"),
        ("31308", "内地榜"), ("33160", "电音榜"), ("31313", "香港地区榜"), ("51341", "民谣榜"),
        ("54848", "台湾地区榜"), ("31310", "欧美榜"), ("33162", "ACG新歌榜"), ("31311", "韩国榜"),
        ("31312", "日本榜"), ("49225", "80后热歌榜"), ("49223", "90后热歌榜"), ("49224", "00后热歌榜"),
        ("33165", "粤语金曲榜"), ("33166", "欧美金曲榜"), ("33163", "影视金曲榜"), ("51340", "伤感榜"),
        ("35811", "会员专享榜"), ("37361", "雷达榜"), ("21101", "分享榜"), ("46910", "综艺新歌榜"),
        ("30972", "酷狗音乐人原创榜"), ("60170", "闽南语榜"), ("65234", "儿歌榜"), ("4681", "美国BillBoard榜"),
        ("25028", "Beatport电子舞曲榜"), ("4680", "英国单曲榜"), ("38623", "韩国Melon音乐榜"),
        ("42807", "joox本地热歌榜"), ("36107", "小语种热歌榜"), ("4673", "日本公信榜"),
        ("46868", "日本SPACE SHOWER榜"), ("42808", "KKBOX风云榜"), ("60171", "越南语榜"),
        ("60172", "泰语榜"), ("59895", "R&B榜"), ("59896", "摇滚榜"), ("59897", "爵士榜"),
        ("59898", "乡村音乐榜"), ("59900", "纯音乐榜"), ("59899", "古典榜"), ("22603", "5sing音乐榜"),
        ("21335", "繁星音乐榜"), ("33161", "古风新歌榜"),
    ].map { LeaderboardBoard(id: "kg__\($0.0)", name: $0.1, bangid: $0.0, source: .kg) }

    // MARK: - Signatures (`kg/util.js` & `kg/vendors/infSign.min.js`)

    static func signatureParams(_ params: String, platform: String = "android", body: String = "") -> String {
        let keyParam = (platform == "web") ? "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt" : "OIlwieks28dk2k092lksi2UIkp"
        let sorted = params.split(separator: "&").map(String.init).sorted().joined()
        return CryptoUtils.md5Hex("\(keyParam)\(sorted)\(body)\(keyParam)")
    }

    static func infSignPlaylist(specialId: String, page: Int, limit: Int) -> String {
        let dict: [String: String] = [
            "srcappid": "2919",
            "clientver": "20000",
            "appid": "1058",
            "type": "0",
            "module": "playlist",
            "page": String(page),
            "pagesize": String(limit),
            "specialid": specialId,
        ]
        let joined = dict.keys.sorted().map { "\($0)=\(dict[$0]!)" }.joined()
        let key = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt"
        return CryptoUtils.md5Hex("\(key)\(joined)\(key)")
    }

    private func kgFetch(
        _ url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        jsonBody: Any? = nil
    ) async throws -> Any {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let payload: HTTPClient.BodyPayload = jsonBody.map { .json($0) } ?? .none
            let resp = try await HTTPClient.shared.request(url, method: method, headers: headers, body: payload)
            guard resp.statusCode == 200 else {
                throw MusicSDKError.httpStatus(resp.statusCode, "KG HTTP error")
            }
            let body = try resp.jsonDictionary()
            let errCode: Int
            if body["error_code"] != nil { errCode = FormatUtils.intValue(body["error_code"]) }
            else if body["errcode"] != nil { errCode = FormatUtils.intValue(body["errcode"]) }
            else if body["err_code"] != nil { errCode = FormatUtils.intValue(body["err_code"]) }
            else { errCode = 0 }
            guard errCode == 0 else {
                throw MusicSDKError.apiError("KG error code: \(errCode)")
            }
            if let data = body["data"] { return data }
            if body["info"] is [Any] { return body }
            if let info = body["info"] { return info }
            return body
        }
    }

    // MARK: - Batch Track Enrichment (`kg/musicInfo.js` / `kg/songList.js`)

    func fetchMusicInfosByHashes(_ hashes: [String]) async throws -> [MusicInfo] {
        var seen = Set<String>()
        let uniqueHashes = hashes.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !uniqueHashes.isEmpty else { return [] }

        let chunks = stride(from: 0, to: uniqueHashes.count, by: 100).map {
            Array(uniqueHashes[$0..<min($0 + 100, uniqueHashes.count)])
        }

        let headers = [
            "KG-THash": "13a3164",
            "KG-RC": "1",
            "KG-Fake": "0",
            "KG-RF": "00869891",
            "User-Agent": "Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi",
            "x-router": "kmr.service.kugou.com",
        ]

        var rawItems: [[String: Any]] = []
        for chunk in chunks {
            let body: [String: Any] = [
                "area_code": "1",
                "show_privilege": 1,
                "show_album_info": "1",
                "is_publish": "",
                "appid": 1005,
                "clientver": 11451,
                "mid": "1",
                "dfid": "-",
                "clienttime": Int64(Date().timeIntervalSince1970 * 1000),
                "key": "OIlwieks28dk2k092lksi2UIkp",
                "fields": "album_info,author_name,audio_info,ori_audio_name,base,songname",
                "data": chunk.map { ["hash": $0] },
            ]
            let data = try await kgFetch("http://gateway.kugou.com/v2/album_audio/audio", method: "POST", headers: headers, jsonBody: body)
            if let rows = data as? [[Any]] {
                for row in rows {
                    if let first = row.first as? [String: Any] {
                        rawItems.append(first)
                    }
                }
            }
        }

        return parseAudioInfoBatch(rawItems)
    }

    private func parseAudioInfoBatch(_ rawList: [[String: Any]]) -> [MusicInfo] {
        var ids = Set<String>()
        var result: [MusicInfo] = []

        for item in rawList {
            guard let audioInfo = item["audio_info"] as? [String: Any] else { continue }
            let audioId = FormatUtils.stringValue(audioInfo["audio_id"])
            guard !audioId.isEmpty, ids.insert(audioId).inserted else { continue }
            let albumInfo = (item["album_info"] as? [String: Any]) ?? [:]

            var types: [MusicQualityItem] = []
            var map: [String: MusicQualityMeta] = [:]

            let fs128 = FormatUtils.int64Value(audioInfo["filesize"])
            if fs128 > 0 {
                let h = FormatUtils.stringValue(audioInfo["hash"])
                let s = FormatUtils.sizeFormate(fs128)
                types.append(MusicQualityItem(type: .k128, size: s, hash: h))
                map[AudioQuality.k128.rawValue] = MusicQualityMeta(size: s, hash: h)
            }
            let fs320 = FormatUtils.int64Value(audioInfo["filesize_320"])
            if fs320 > 0 {
                let h = FormatUtils.stringValue(audioInfo["hash_320"])
                let s = FormatUtils.sizeFormate(fs320)
                types.append(MusicQualityItem(type: .k320, size: s, hash: h))
                map[AudioQuality.k320.rawValue] = MusicQualityMeta(size: s, hash: h)
            }
            let fsFlac = FormatUtils.int64Value(audioInfo["filesize_flac"])
            if fsFlac > 0 {
                let h = FormatUtils.stringValue(audioInfo["hash_flac"])
                let s = FormatUtils.sizeFormate(fsFlac)
                types.append(MusicQualityItem(type: .flac, size: s, hash: h))
                map[AudioQuality.flac.rawValue] = MusicQualityMeta(size: s, hash: h)
            }
            let fsHigh = FormatUtils.int64Value(audioInfo["filesize_high"])
            if fsHigh > 0 {
                let h = FormatUtils.stringValue(audioInfo["hash_high"])
                let s = FormatUtils.sizeFormate(fsHigh)
                types.append(MusicQualityItem(type: .flac24bit, size: s, hash: h))
                map[AudioQuality.flac24bit.rawValue] = MusicQualityMeta(size: s, hash: h)
            }

            let hash = FormatUtils.stringValue(audioInfo["hash"])
            let timelength = Double(FormatUtils.int64Value(audioInfo["timelength"])) / 1000.0

            result.append(MusicInfo(
                id: "\(audioId)_\(hash)",
                name: FormatUtils.decodeName(item["songname"] as? String),
                singer: FormatUtils.decodeName(item["author_name"] as? String),
                source: .kg,
                interval: FormatUtils.formatPlayTime(timelength),
                meta: MusicMeta(
                    songId: audioId,
                    albumName: FormatUtils.decodeName(albumInfo["album_name"] as? String),
                    picUrl: nil,
                    albumId: FormatUtils.stringValue(albumInfo["album_id"]),
                    qualitys: types,
                    _qualitys: map,
                    hash: hash,
                    albumAudioId: FormatUtils.stringValue(audioInfo["audio_group_id"])
                )
            ))
        }
        return result
    }

    // MARK: - Search (`kg/musicSearch.js`)

    func searchMusic(query: String, page: Int, limit: Int = 30) async throws -> MusicSearchPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let url = "http://songsearch.kugou.com/song_search_v2?platform=AndroidFilter&iscorrection=1&keyword=\(FormatUtils.urlEncodeComponent(query))&hifiquality=0&pagesize=\(limit)&PrivilegeFilter=0&page=\(page)"
            let resp = try await HTTPClient.shared.get(url)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["error_code"]) == 0,
                  let data = body["data"] as? [String: Any],
                  let lists = data["lists"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("KG search failed")
            }

            var seen = Set<String>()
            var result: [MusicInfo] = []
            for raw in lists {
                let audioId = FormatUtils.stringValue(raw["Audioid"])
                let fileHash = FormatUtils.stringValue(raw["FileHash"])
                let key = "\(audioId)\(fileHash)"
                guard !fileHash.isEmpty, seen.insert(key).inserted else { continue }

                var types: [MusicQualityItem] = []
                var map: [String: MusicQualityMeta] = [:]
                let fs128 = FormatUtils.int64Value(raw["FileSize"])
                if fs128 > 0 {
                    let s = FormatUtils.sizeFormate(fs128)
                    types.append(MusicQualityItem(type: .k128, size: s, hash: fileHash))
                    map[AudioQuality.k128.rawValue] = MusicQualityMeta(size: s, hash: fileHash)
                }
                let fs320 = FormatUtils.int64Value(raw["HQFileSize"])
                if fs320 > 0 {
                    let h = FormatUtils.stringValue(raw["HQFileHash"])
                    let s = FormatUtils.sizeFormate(fs320)
                    types.append(MusicQualityItem(type: .k320, size: s, hash: h))
                    map[AudioQuality.k320.rawValue] = MusicQualityMeta(size: s, hash: h)
                }
                let fsFlac = FormatUtils.int64Value(raw["SQFileSize"])
                if fsFlac > 0 {
                    let h = FormatUtils.stringValue(raw["SQFileHash"])
                    let s = FormatUtils.sizeFormate(fsFlac)
                    types.append(MusicQualityItem(type: .flac, size: s, hash: h))
                    map[AudioQuality.flac.rawValue] = MusicQualityMeta(size: s, hash: h)
                }
                let fsRes = FormatUtils.int64Value(raw["ResFileSize"])
                if fsRes > 0 {
                    let h = FormatUtils.stringValue(raw["ResFileHash"])
                    let s = FormatUtils.sizeFormate(fsRes)
                    types.append(MusicQualityItem(type: .flac24bit, size: s, hash: h))
                    map[AudioQuality.flac24bit.rawValue] = MusicQualityMeta(size: s, hash: h)
                }

                let oriName = FormatUtils.stringValue(raw["OriSongName"])
                let suffix = FormatUtils.stringValue(raw["Suffix"])
                let fullName = suffix.isEmpty ? oriName : "\(oriName) \(suffix)"
                let singers = raw["Singers"] as? [[String: Any]]
                let singerStr = singers != nil
                    ? FormatUtils.formatSingerName(singers, nameKey: "name")
                    : FormatUtils.decodeName(raw["SingerName"] as? String)

                result.append(MusicInfo(
                    id: "\(audioId)_\(fileHash)",
                    name: FormatUtils.decodeName(fullName),
                    singer: singerStr,
                    source: .kg,
                    interval: FormatUtils.formatPlayTime(FormatUtils.intValue(raw["Duration"])),
                    meta: MusicMeta(
                        songId: audioId,
                        albumName: FormatUtils.decodeName(raw["AlbumName"] as? String),
                        picUrl: nil,
                        albumId: FormatUtils.stringValue(raw["AlbumID"]),
                        qualitys: types,
                        _qualitys: map,
                        hash: fileHash,
                        albumAudioId: FormatUtils.stringValue(raw["MixSongID"])
                    )
                ))
            }

            let total = FormatUtils.intValue(data["total"])
            let allPage = max(1, Int(ceil(Double(total) / Double(max(1, limit)))))
            return MusicSearchPage(list: result, page: page, allPage: allPage, limit: limit, total: total, source: .kg)
        }
    }

    func getHotSearch() async throws -> [String] {
        let url = "http://gateway.kugou.com/api/v3/search/hot_tab?signature=ee44edb9d7155821412d220bcaf509dd&appid=1005&clientver=10026&plat=0"
        let headers = [
            "dfid": "1ssiv93oVqMp27cirf2CvoF1",
            "mid": "156798703528610303473757548878786007104",
            "clienttime": "1584257267",
            "x-router": "msearch.kugou.com",
            "user-agent": "Android9-AndroidPhone-10020-130-0-searchrecommendprotocol-wifi",
            "kg-rc": "1",
        ]
        let resp = try await HTTPClient.shared.get(url, headers: headers)
        let body = try resp.jsonDictionary()
        guard resp.statusCode == 200, FormatUtils.intValue(body["errcode"]) == 0,
              let data = body["data"] as? [String: Any],
              let list = data["list"] as? [[String: Any]] else {
            throw MusicSDKError.apiError("获取酷狗热搜词失败")
        }
        var words: [String] = []
        for group in list {
            if let keywords = group["keywords"] as? [[String: Any]] {
                for kw in keywords {
                    let word = FormatUtils.decodeName(kw["keyword"] as? String)
                    if !word.isEmpty { words.append(word) }
                }
            }
        }
        return words
    }

    func getTipSearch(query: String) async throws -> [String] {
        let url = "https://searchtip.kugou.com/getSearchTip?MusicTipCount=10&keyword=\(FormatUtils.urlEncodeComponent(query))"
        let data = try await kgFetch(url, headers: ["referer": "https://www.kugou.com/"])
        guard let arr = data as? [[String: Any]], let first = arr.first,
              let records = first["RecordDatas"] as? [[String: Any]] else {
            return []
        }
        return records.compactMap { $0["HintInfo"] as? String }
    }

    // MARK: - Leaderboard (`kg/leaderboard.js`)

    func getLeaderboardTracks(bangId: String, page: Int) async throws -> LeaderboardPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let limit = 100
            let url = "http://mobilecdnbj.kugou.com/api/v3/rank/song?version=9108&ranktype=1&plat=0&pagesize=\(limit)&area_code=1&page=\(page)&rankid=\(bangId)&with_res_tag=0&show_portrait_mv=1"
            let resp = try await HTTPClient.shared.get(url)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["errcode"]) == 0,
                  let data = body["data"] as? [String: Any],
                  let info = data["info"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("KG leaderboard failed")
            }

            let list: [MusicInfo] = info.compactMap { item in
                let audioId = FormatUtils.stringValue(item["audio_id"])
                let hash = FormatUtils.stringValue(item["hash"])
                guard !hash.isEmpty else { return nil }

                var types: [MusicQualityItem] = []
                var map: [String: MusicQualityMeta] = [:]
                let fs128 = FormatUtils.int64Value(item["filesize"])
                if fs128 > 0 {
                    let s = FormatUtils.sizeFormate(fs128)
                    types.append(MusicQualityItem(type: .k128, size: s, hash: hash))
                    map[AudioQuality.k128.rawValue] = MusicQualityMeta(size: s, hash: hash)
                }
                let fs320 = FormatUtils.int64Value(item["320filesize"])
                if fs320 > 0 {
                    let h = FormatUtils.stringValue(item["320hash"])
                    let s = FormatUtils.sizeFormate(fs320)
                    types.append(MusicQualityItem(type: .k320, size: s, hash: h))
                    map[AudioQuality.k320.rawValue] = MusicQualityMeta(size: s, hash: h)
                }
                let fsSq = FormatUtils.int64Value(item["sqfilesize"])
                if fsSq > 0 {
                    let h = FormatUtils.stringValue(item["sqhash"])
                    let s = FormatUtils.sizeFormate(fsSq)
                    types.append(MusicQualityItem(type: .flac, size: s, hash: h))
                    map[AudioQuality.flac.rawValue] = MusicQualityMeta(size: s, hash: h)
                }
                let fsHigh = FormatUtils.int64Value(item["filesize_high"])
                if fsHigh > 0 {
                    let h = FormatUtils.stringValue(item["hash_high"])
                    let s = FormatUtils.sizeFormate(fsHigh)
                    types.append(MusicQualityItem(type: .flac24bit, size: s, hash: h))
                    map[AudioQuality.flac24bit.rawValue] = MusicQualityMeta(size: s, hash: h)
                }

                let authors = item["authors"] as? [[String: Any]]
                let singer = FormatUtils.formatSingerName(authors, nameKey: "author_name")

                return MusicInfo(
                    id: "\(audioId)_\(hash)",
                    name: FormatUtils.decodeName(item["songname"] as? String),
                    singer: singer,
                    source: .kg,
                    interval: FormatUtils.formatPlayTime(FormatUtils.intValue(item["duration"])),
                    meta: MusicMeta(
                        songId: audioId,
                        albumName: FormatUtils.decodeName(item["remark"] as? String),
                        picUrl: nil,
                        albumId: FormatUtils.stringValue(item["album_id"]),
                        qualitys: types,
                        _qualitys: map,
                        hash: hash,
                        albumAudioId: FormatUtils.stringValue(item["album_audio_id"])
                    )
                )
            }

            return LeaderboardPage(list: list, page: page, limit: limit, total: FormatUtils.intValue(data["total"]), source: .kg)
        }
    }

    // MARK: - SongList (`kg/songList.js`)

    func getSongListTags() async throws -> SongListTagsResult {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let resp = try await HTTPClient.shared.get("http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_smarty=1&")
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["status"]) == 1,
                  let data = body["data"] as? [String: Any] else {
                throw MusicSDKError.apiError("KG getTags failed")
            }

            var hotTag: [SongListTagItem] = []
            if let ht = data["hotTag"] as? [String: Any], FormatUtils.intValue(ht["status"]) == 1,
               let htData = ht["data"] as? [String: Any] {
                for key in htData.keys.sorted() {
                    if let tag = htData[key] as? [String: Any] {
                        hotTag.append(SongListTagItem(
                            id: FormatUtils.stringValue(tag["special_id"]),
                            name: FormatUtils.stringValue(tag["special_name"]),
                            source: .kg
                        ))
                    }
                }
            }

            var groups: [SongListTagGroup] = []
            if let tagIds = data["tagids"] as? [String: Any] {
                for name in tagIds.keys.sorted() {
                    if let grp = tagIds[name] as? [String: Any], let arr = grp["data"] as? [[String: Any]] {
                        let items = arr.map { tag in
                            SongListTagItem(
                                id: FormatUtils.stringValue(tag["id"]),
                                name: FormatUtils.stringValue(tag["name"]),
                                parentId: FormatUtils.stringValue(tag["parent_id"]),
                                parentName: FormatUtils.stringValue(tag["pname"]),
                                source: .kg
                            )
                        }
                        groups.append(SongListTagGroup(name: name, list: items))
                    }
                }
            }
            return SongListTagsResult(hotTag: hotTag, tags: groups, source: .kg)
        }
    }

    func getSongList(sortId: String, tagId: String?, page: Int) async throws -> SongListSearchPage {
        let tagParam = tagId ?? ""
        async let listTask = fetchSpecialList(sortId: sortId, tagId: tagParam, page: page)
        async let infoTask = fetchSpecialInfo(tagId: tagParam)
        async let recTask: [OnlineSongListItem] = (tagParam.isEmpty && page == 1 && sortId == "5")
            ? ((try? await fetchRecommendSpecialList()) ?? [])
            : []

        var (list, info, recs) = try await (listTask, infoTask, recTask)
        if !recs.isEmpty {
            list.insert(contentsOf: recs, at: 0)
        }
        return SongListSearchPage(list: list, page: page, limit: info.limit, total: info.total, source: .kg)
    }

    private func fetchSpecialList(sortId: String, tagId: String, page: Int) async throws -> [OnlineSongListItem] {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let url = "http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_ajax=1&cdn=cdn&t=\(sortId)&c=\(tagId)&p=\(page)"
            let resp = try await HTTPClient.shared.get(url)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["status"]) == 1,
                  let db = body["special_db"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("KG getSongList failed")
            }
            return self.parseSpecialItems(db)
        }
    }

    private func fetchSpecialInfo(tagId: String) async throws -> (limit: Int, total: Int) {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let url = tagId.isEmpty
                ? "http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_smarty=1&"
                : "http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_smarty=1&cdn=cdn&t=5&c=\(tagId)"
            let resp = try await HTTPClient.shared.get(url)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["status"]) == 1,
                  let data = body["data"] as? [String: Any],
                  let params = data["params"] as? [String: Any] else {
                throw MusicSDKError.apiError("KG getListInfo failed")
            }
            return (FormatUtils.intValue(params["pagesize"]), FormatUtils.intValue(params["total"]))
        }
    }

    private func fetchRecommendSpecialList() async throws -> [OnlineSongListItem] {
        let body: [String: Any] = [
            "appid": 1001,
            "clienttime": 1566798337219,
            "clientver": 8275,
            "key": "f1f93580115bb106680d2375f8032d96",
            "mid": "21511157a05844bd085308bc76ef3343",
            "platform": "pc",
            "userid": "262643156",
            "return_min": 6,
            "return_max": 15,
        ]
        let resp = try await HTTPClient.shared.postJSON(
            "http://everydayrec.service.kugou.com/guess_special_recommend",
            json: body,
            headers: ["User-Agent": "KuGou2012-8275-web_browser_event_handler"]
        )
        let json = try resp.jsonDictionary()
        guard FormatUtils.intValue(json["status"]) == 1,
              let data = json["data"] as? [String: Any],
              let list = data["special_list"] as? [[String: Any]] else {
            return []
        }
        return parseSpecialItems(list)
    }

    private func parseSpecialItems(_ rawList: [[String: Any]]) -> [OnlineSongListItem] {
        rawList.map { item in
            let playCountStr: String
            if let tpc = item["total_play_count"] as? String, !tpc.isEmpty {
                playCountStr = tpc
            } else {
                playCountStr = FormatUtils.formatPlayCount(FormatUtils.int64Value(item["play_count"]))
            }
            let img = (item["img"] as? String) ?? (item["imgurl"] as? String)
            return OnlineSongListItem(
                id: "id_\(FormatUtils.stringValue(item["specialid"]))",
                name: FormatUtils.decodeName(item["specialname"] as? String),
                author: FormatUtils.decodeName(item["nickname"] as? String),
                img: img?.replacingOccurrences(of: "{size}", with: "240"),
                playCount: playCountStr,
                desc: FormatUtils.decodeName(item["intro"] as? String),
                total: FormatUtils.intValue(item["songcount"]),
                time: FormatUtils.formatDateYMD(fromString: (item["publish_time"] as? String) ?? (item["publishtime"] as? String)),
                source: .kg
            )
        }
    }

    func searchSongList(query: String, page: Int, limit: Int = 20) async throws -> SongListSearchPage {
        let url = "http://msearchretry.kugou.com/api/v3/search/special?keyword=\(FormatUtils.urlEncodeComponent(query))&page=\(page)&pagesize=\(limit)&showtype=10&filter=0&version=7910&sver=2"
        let resp = try await HTTPClient.shared.get(url)
        let body = try resp.jsonDictionary()
        guard FormatUtils.intValue(body["errcode"]) == 0,
              let data = body["data"] as? [String: Any],
              let info = data["info"] as? [[String: Any]] else {
            throw MusicSDKError.apiError("KG searchSongList failed")
        }
        let list = info.map { item in
            OnlineSongListItem(
                id: "id_\(FormatUtils.stringValue(item["specialid"]))",
                name: FormatUtils.decodeName(item["specialname"] as? String),
                author: FormatUtils.decodeName(item["nickname"] as? String),
                img: (item["imgurl"] as? String)?.replacingOccurrences(of: "{size}", with: "240"),
                playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(item["playcount"])),
                desc: FormatUtils.decodeName(item["intro"] as? String),
                total: FormatUtils.intValue(item["songcount"]),
                time: FormatUtils.formatDateYMD(fromString: item["publishtime"] as? String),
                source: .kg
            )
        }
        return SongListSearchPage(list: list, page: page, limit: limit, total: FormatUtils.intValue(data["total"]), source: .kg)
    }

    func getSongListDetail(idOrUrl: String, page: Int) async throws -> SongListDetailPage {
        var id = idOrUrl.trimmingCharacters(in: .whitespacesAndNewlines)

        if id.contains("special/single/") {
            if let m = RegexHelper.firstMatch(#"/(\d+)\.html"#, in: id), m.count >= 2 {
                id = m[1]
            }
        } else if RegexHelper.test(#"https?:"#, in: id) {
            if let r = id.range(of: "http") {
                return try await fetchUserSongListByURL(String(id[r.lowerBound...]), page: page)
            }
        } else if RegexHelper.test(#"^\d+$"#, in: id) {
            return try await fetchUserSongListByCode(id)
        } else if id.hasPrefix("id_") {
            id = String(id.dropFirst(3))
        }

        return try await fetchSongListDetailBySpecialId(id)
    }

    private func fetchSongListDetailBySpecialId(_ id: String) async throws -> SongListDetailPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let url = "http://www2.kugou.kugou.com/yueku/v9/special/single/\(id)-5-9999.html"
            let resp = try await HTTPClient.shared.get(url)
            let html = resp.text
            guard let dataMatch = RegexHelper.firstMatch(#"global\.data = (\[.+\]);"#, in: html), dataMatch.count >= 2,
                  let jsonData = dataMatch[1].data(using: .utf8),
                  let rawArr = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
                throw MusicSDKError.parseError("KG special HTML missing global.data")
            }

            let hashes = rawArr.compactMap { $0["hash"] as? String }
            let tracks = try await self.fetchMusicInfosByHashes(hashes)

            let infoMatch = RegexHelper.firstMatch(#"global = \{[\s\S]+?name: "(.+)"[\s\S]+?pic: "(.+)"[\s\S]+?\};"#, in: html)
            let name = infoMatch.flatMap { $0.count >= 2 ? $0[1] : nil } ?? ""
            let pic = infoMatch.flatMap { $0.count >= 3 ? $0[2] : nil }
            var desc: String?
            let prefix = "<div class=\"pc_specail_text pc_singer_tab_content\" id=\"specailIntroduceWrap\">"
            if let start = html.range(of: prefix),
               let end = html[start.upperBound...].range(of: "</div>") {
                desc = FormatUtils.decodeName(String(html[start.upperBound..<end.lowerBound]))
            }

            return SongListDetailPage(
                list: tracks,
                page: 1,
                limit: 10000,
                total: tracks.count,
                source: .kg,
                info: OnlineSongListInfo(name: name, img: pic, desc: desc, author: nil, playCount: nil)
            )
        }
    }

    private func fetchUserSongListByCode(_ code: String) async throws -> SongListDetailPage {
        let headers = [
            "KG-RC": "1",
            "KG-THash": "network_super_call.cpp:3676261689:379",
            "User-Agent": "",
        ]
        let body: [String: Any] = [
            "appid": 1001, "clientver": 9020,
            "mid": "21511157a05844bd085308bc76ef3343",
            "clienttime": 640612895,
            "key": "36164c4015e704673c588ee202b9ecb8",
            "data": code,
        ]
        let raw = try await kgFetch("http://t.kugou.com/command/", method: "POST", headers: headers, jsonBody: body)
        guard let songInfo = raw as? [String: Any], let info = songInfo["info"] as? [String: Any] else {
            throw MusicSDKError.parseError("无法解析酷狗码")
        }
        let gcid = FormatUtils.stringValue(info["global_collection_id"])
        if !gcid.isEmpty {
            return try await fetchUserSongListByGlobalId(gcid)
        }
        if FormatUtils.intValue(info["type"]) == 2 {
            return try await fetchSongListDetailBySpecialId(FormatUtils.stringValue(info["id"]))
        }
        var rawSongs = (songInfo["list"] as? [[String: Any]]) ?? []
        if info["userid"] != nil {
            let listBody: [String: Any] = [
                "appid": 1001, "clientver": 9020,
                "mid": "21511157a05844bd085308bc76ef3343",
                "clienttime": 640612895,
                "key": "36164c4015e704673c588ee202b9ecb8",
                "data": [
                    "id": info["id"] ?? 0,
                    "type": 3,
                    "userid": info["userid"] ?? 0,
                    "collect_type": 0,
                    "page": 1,
                    "pagesize": FormatUtils.intValue(info["count"]),
                ],
            ]
            if let arr = try await kgFetch("http://www2.kugou.kugou.com/apps/kucodeAndShare/app/", method: "POST", headers: headers, jsonBody: listBody) as? [[String: Any]] {
                rawSongs = arr
            }
        }
        let tracks = try await fetchMusicInfosByHashes(rawSongs.compactMap { $0["hash"] as? String })
        let img = (info["img_size"] as? String)?.replacingOccurrences(of: "{size}", with: "240") ?? (info["img"] as? String)
        return SongListDetailPage(
            list: tracks, page: 1, limit: max(tracks.count, 1), total: tracks.count, source: .kg,
            info: OnlineSongListInfo(name: FormatUtils.stringValue(info["name"]), img: img, desc: nil, author: FormatUtils.stringValue(info["username"]), playCount: nil)
        )
    }

    private func decodeGcid(_ gcid: String) async throws -> String {
        let params = "dfid=-&appid=1005&mid=0&clientver=20109&clienttime=640612895&uuid=-"
        let body: [String: Any] = ["ret_info": 1, "data": [["id": gcid, "id_type": 2]]]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? ""
        let sig = Self.signatureParams(params, platform: "android", body: jsonStr)
        let url = "https://t.kugou.com/v1/songlist/batch_decode?\(params)&signature=\(sig)"
        let resp = try await HTTPClient.shared.request(
            url, method: "POST",
            headers: [
                "User-Agent": "Mozilla/5.0 (Linux; Android 10; HUAWEI HMA-AL00) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.106 Mobile Safari/537.36",
                "Referer": "https://m.kugou.com/",
            ],
            body: .jsonString(jsonStr)
        )
        let dict = try resp.jsonDictionary()
        guard let data = dict["data"] as? [String: Any],
              let list = data["list"] as? [[String: Any]],
              let first = list.first,
              let globalId = first["global_collection_id"] as? String else {
            throw MusicSDKError.parseError("decodeGcid failed")
        }
        return globalId
    }

    private func fetchUserSongListByGlobalId(_ globalId: String) async throws -> SongListDetailPage {
        let params = "appid=1058&specialid=0&global_specialid=\(globalId)&format=jsonp&srcappid=2919&clientver=20000&clienttime=1586163242519&mid=1586163242519&uuid=1586163242519&dfid=-"
        let infoUrl = "https://mobiles.kugou.com/api/v5/special/info_v2?\(params)&signature=\(Self.signatureParams(params, platform: "web"))"
        let headers = [
            "mid": "1586163242519",
            "Referer": "https://m3ws.kugou.com/share/index.php",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 11_0 like Mac OS X) AppleWebKit/604.1.38 (KHTML, like Gecko) Version/11.0 Mobile/15A372 Safari/604.1",
            "dfid": "-",
            "clienttime": "1586163242519",
        ]
        guard let info = try await kgFetch(infoUrl, headers: headers) as? [String: Any] else {
            throw MusicSDKError.parseError("KG global special info failed")
        }

        var remaining = FormatUtils.intValue(info["songcount"])
        var page = 0
        var hashes: [String] = []
        while remaining > 0 {
            let limit = min(300, remaining)
            remaining -= limit
            page += 1
            let p = "appid=1058&global_specialid=\(globalId)&specialid=0&plat=0&version=8000&page=\(page)&pagesize=\(limit)&srcappid=2919&clientver=20000&clienttime=1586163263991&mid=1586163263991&uuid=1586163263991&dfid=-"
            let u = "https://mobiles.kugou.com/api/v5/special/song_v2?\(p)&signature=\(Self.signatureParams(p, platform: "web"))"
            if let pageData = try await kgFetch(u, headers: headers) as? [String: Any],
               let songArr = pageData["info"] as? [[String: Any]] {
                hashes.append(contentsOf: songArr.compactMap { $0["hash"] as? String })
            }
        }

        let tracks = try await fetchMusicInfosByHashes(hashes)
        return SongListDetailPage(
            list: tracks, page: 1, limit: 10000, total: tracks.count, source: .kg,
            info: OnlineSongListInfo(
                name: FormatUtils.stringValue(info["specialname"]),
                img: (info["imgurl"] as? String)?.replacingOccurrences(of: "{size}", with: "240"),
                desc: FormatUtils.stringValue(info["intro"]),
                author: FormatUtils.stringValue(info["nickname"]),
                playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(info["playcount"]))
            )
        )
    }

    private func fetchUserSongListByURL(_ rawLink: String, page: Int, depth: Int = 0) async throws -> SongListDetailPage {
        guard depth <= 3 else { throw MusicSDKError.apiError("酷狗分享链接解析失败") }
        var link = rawLink
        if let hashIdx = link.firstIndex(of: "#") {
            link = String(link[..<hashIdx])
        }

        if let gcid = RegexHelper.firstMatch(#"gcid_\w+"#, in: link)?.first, !gcid.isEmpty {
            let globalId = try await decodeGcid(gcid)
            return try await fetchUserSongListByGlobalId(globalId)
        }
        if let m = RegexHelper.firstMatch(#"global_collection_id=(\w+)"#, in: link), m.count >= 2 {
            return try await fetchUserSongListByGlobalId(m[1])
        }
        if let m = RegexHelper.firstMatch(#"chain=(\w+)"#, in: link), m.count >= 2 {
            return try await fetchUserSongListByChain(m[1], page: page)
        }

        let resp = try await HTTPClient.shared.get(
            link,
            headers: [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 9_1 like Mac OS X) AppleWebKit/601.1.46 (KHTML, like Gecko) Version/9.0 Mobile/13B143 Safari/601.1",
                "Referer": link,
            ],
            followRedirects: false
        )
        if let loc = resp.header("location"), !loc.isEmpty {
            return try await fetchUserSongListByURL(loc, page: page, depth: depth + 1)
        }
        let bodyText = resp.text
        if let m = RegexHelper.firstMatch(#""global_collection_id":"(\w+)""#, in: bodyText), m.count >= 2 {
            return try await fetchUserSongListByGlobalId(m[1])
        }
        if let m = RegexHelper.firstMatch(#""encode_(?:gic|src_gid)":"(\w+)""#, in: bodyText), m.count >= 2 {
            let globalId = try await decodeGcid(m[1])
            return try await fetchUserSongListByGlobalId(globalId)
        }
        throw MusicSDKError.parseError("无法解析酷狗歌单链接")
    }

    private func fetchUserSongListByChain(_ chain: String, page: Int) async throws -> SongListDetailPage {
        let url = "http://m.kugou.com/schain/transfer?pagesize=10000&chain=\(chain)&su=1&page=\(page)&n=0.7928855356604456"
        let headers = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 9_1 like Mac OS X) AppleWebKit/601.1.46 (KHTML, like Gecko) Version/9.0 Mobile/13B143 Safari/601.1"]
        guard let songInfo = try await kgFetch(url, headers: headers) as? [String: Any] else {
            throw MusicSDKError.parseError("KG chain transfer failed")
        }
        if let listArr = songInfo["list"] as? [[String: Any]] {
            let tracks = try await fetchMusicInfosByHashes(listArr.compactMap { $0["hash"] as? String })
            let info = (songInfo["info"] as? [String: Any]) ?? [:]
            return SongListDetailPage(
                list: tracks, page: 1, limit: 10000, total: tracks.count, source: .kg,
                info: OnlineSongListInfo(name: FormatUtils.stringValue(info["name"]), img: info["img"] as? String, desc: nil, author: FormatUtils.stringValue(info["username"]), playCount: nil)
            )
        }
        if let gcid = songInfo["global_collection_id"] as? String, !gcid.isEmpty {
            return try await fetchUserSongListByGlobalId(gcid)
        }
        let specialId = FormatUtils.stringValue(songInfo["id"])
        let sig = Self.infSignPlaylist(specialId: specialId, page: page, limit: 100)
        let listUrl = "https://pubsongscdn.kugou.com/v2/get_other_list_file?srcappid=2919&clientver=20000&appid=1058&type=0&module=playlist&page=\(page)&pagesize=100&specialid=\(specialId)&signature=\(sig)"
        let rawList = try await kgFetch(listUrl, headers: [
            "Referer": "https://m3ws.kugou.com/share/index.php",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 11_0 like Mac OS X) AppleWebKit/604.1.38 (KHTML, like Gecko) Version/11.0 Mobile/15A372 Safari/604.1",
            "dfid": "-",
        ])
        let items = ((rawList as? [String: Any])?["info"] as? [[String: Any]]) ?? []
        let tracks = try await fetchMusicInfosByHashes(items.compactMap { $0["hash"] as? String })
        return SongListDetailPage(
            list: tracks, page: page, limit: 100, total: tracks.count, source: .kg,
            info: OnlineSongListInfo(name: "酷狗歌单", img: nil, desc: nil, author: nil, playCount: nil)
        )
    }

    // MARK: - Pic (`kg/pic.js`)

    func getPic(musicInfo: MusicInfo) async throws -> String {
        let hash = musicInfo.meta.hash ?? ""
        let body: [String: Any] = [
            "appid": 1001,
            "area_code": "1",
            "behavior": "play",
            "clientver": "9020",
            "need_hash_offset": 1,
            "relate": 1,
            "resource": [[
                "album_audio_id": musicInfo.meta.songId,
                "album_id": musicInfo.meta.albumId ?? "",
                "hash": hash,
                "id": 0,
                "name": "\(musicInfo.singer) - \(musicInfo.name).mp3",
                "type": "audio",
            ]],
            "token": "",
            "userid": 2626431536,
            "vip": 1,
        ]
        let headers = [
            "KG-RC": "1",
            "KG-THash": "expand_search_manager.cpp:852736169:451",
            "User-Agent": "KuGou2012-9020-ExpandSearchManager",
        ]
        let resp = try await HTTPClient.shared.postJSON("http://media.store.kugou.com/v1/get_res_privilege", json: body, headers: headers)
        let dict = try resp.jsonDictionary()
        guard FormatUtils.intValue(dict["error_code"]) == 0,
              let data = dict["data"] as? [[String: Any]],
              let first = data.first,
              let info = first["info"] as? [String: Any],
              var image = info["image"] as? String, !image.isEmpty else {
            throw MusicSDKError.picNotFound
        }
        if let sizes = info["imgsize"] as? [Any], let firstSize = sizes.first {
            image = image.replacingOccurrences(of: "{size}", with: FormatUtils.stringValue(firstSize))
        }
        return image
    }

    // MARK: - Lyric (`kg/lyric.js` + `common/utils/lyricUtils/kg.js`)

    private static let krcKey: [UInt8] = [
        0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47,
        0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69,
    ]

    func getLyric(musicInfo: MusicInfo) async throws -> LyricInfo {
        let headers = [
            "KG-RC": "1",
            "KG-THash": "expand_search_manager.cpp:852736169:451",
            "User-Agent": "KuGou2012-9020-ExpandSearchManager",
        ]
        let hash = musicInfo.meta.hash ?? ""
        let timeSec = FormatUtils.parseIntervalSeconds(musicInfo.interval)
        let searchUrl = "http://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=\(FormatUtils.urlEncodeComponent(musicInfo.name))&hash=\(hash)&timelength=\(timeSec)&lrctxt=1"

        let searchResp = try await HTTPClient.withRetry(maxAttempts: 3) {
            let r = try await HTTPClient.shared.get(searchUrl, headers: headers)
            guard r.statusCode == 200 else { throw MusicSDKError.lyricNotFound }
            return try r.jsonDictionary()
        }

        guard let candidates = searchResp["candidates"] as? [[String: Any]],
              let candidate = candidates.first else {
            throw MusicSDKError.lyricNotFound
        }
        let id = FormatUtils.stringValue(candidate["id"])
        let accessKey = FormatUtils.stringValue(candidate["accesskey"])
        let krctype = FormatUtils.intValue(candidate["krctype"])
        let contenttype = FormatUtils.intValue(candidate["contenttype"])
        let fmt = (krctype == 1 && contenttype != 1) ? "krc" : "lrc"

        let dlUrl = "http://lyrics.kugou.com/download?ver=1&client=pc&id=\(id)&accesskey=\(accessKey)&fmt=\(fmt)&charset=utf8"
        let dlResp = try await HTTPClient.withRetry(maxAttempts: 3) {
            let r = try await HTTPClient.shared.get(dlUrl, headers: headers)
            guard r.statusCode == 200 else { throw MusicSDKError.lyricNotFound }
            return try r.jsonDictionary()
        }

        let actualFmt = FormatUtils.stringValue(dlResp["fmt"])
        let content = FormatUtils.stringValue(dlResp["content"])
        switch actualFmt {
        case "krc":
            return try Self.decodeKRC(base64Content: content)
        case "lrc":
            guard let raw = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
                  let text = String(data: raw, encoding: .utf8) else {
                throw MusicSDKError.lyricNotFound
            }
            return LyricInfo(lyric: text, tlyric: "", lxlyric: "")
        default:
            throw MusicSDKError.lyricNotFound
        }
    }

    /// Exact port of `src/common/utils/lyricUtils/kg.js` (KRC 4-byte header skip + 16-byte XOR + zlib + `[language:...]` base64 JSON).
    static func decodeKRC(base64Content: String) throws -> LyricInfo {
        guard !base64Content.isEmpty,
              let decoded = Data(base64Encoded: base64Content, options: .ignoreUnknownCharacters),
              decoded.count > 4 else {
            throw MusicSDKError.lyricNotFound
        }
        var bytes = Array(decoded.dropFirst(4))
        for i in 0..<bytes.count {
            bytes[i] ^= krcKey[i % 16]
        }
        let inflated = try CryptoUtils.zlibInflate(Data(bytes))
        var str = (String(data: inflated, encoding: .utf8) ?? String(decoding: inflated, as: UTF8.self))
            .replacingOccurrences(of: "\r", with: "")

        // Remove [id:$...] header line
        str = RegexHelper.replace(#"^.*\[id:\$\w+\]\n"#, in: str, with: "")

        var tLines: [String]?

        if let langMatch = RegexHelper.firstMatch(#"\[language:([\w=\\/+]+)\]"#, in: str), langMatch.count >= 2 {
            str = RegexHelper.replace(#"\[language:[\w=\\/+]+\]\n?"#, in: str, with: "")
            if let langData = Data(base64Encoded: langMatch[1], options: .ignoreUnknownCharacters),
               let langJSON = try? JSONSerialization.jsonObject(with: langData) as? [String: Any],
               let contentArr = langJSON["content"] as? [[String: Any]] {
                for item in contentArr {
                    let type = FormatUtils.intValue(item["type"])
                    if type == 1, let rawContent = item["lyricContent"] as? [[String]] {
                        tLines = rawContent.map { $0.joined() }
                    }
                }
            }
        }

        var lineIndex = 0
        var outLxLines: [String] = []
        var outT: [String] = []

        for line in str.components(separatedBy: "\n") {
            if let m = RegexHelper.firstMatch(#"^\[((\d+),\d+)\](.*)$"#, in: line), m.count >= 4 {
                let startMs = Int(m[2]) ?? 0
                let ms = String(format: "%03d", startMs % 1000)
                let totalSec = startMs / 1000
                let mm = String(format: "%02d", totalSec / 60)
                let ss = String(format: "%02d", totalSec % 60)
                let timeTag = "\(mm):\(ss).\(ms)"

                outLxLines.append("[\(timeTag)]\(m[3])")
                if let t = tLines, lineIndex < t.count {
                    outT.append("[\(timeTag)]\(t[lineIndex])")
                }
                lineIndex += 1
            } else {
                outLxLines.append(line)
            }
        }

        var lxlyric = outLxLines.joined(separator: "\n")
        lxlyric = RegexHelper.replace(#"<(\d+,\d+),\d+>"#, in: lxlyric, with: "<$1>")
        lxlyric = FormatUtils.decodeLyricEntities(lxlyric)
        let plainLyric = RegexHelper.replace(#"<\d+,\d+>"#, in: lxlyric, with: "")
        let tlyric = FormatUtils.decodeLyricEntities(outT.joined(separator: "\n"))

        return LyricInfo(lyric: plainLyric, tlyric: tlyric, lxlyric: lxlyric)
    }
}
