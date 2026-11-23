import Foundation

/// Native Swift port of Kuwo Music SDK (`src/renderer/utils/musicSdk/kw/`).
final class KWMusicSDK: MusicSDK, @unchecked Sendable {
    let source: MusicSource = .kw

    let songListSortOptions: [SongListSortOption] = [
        SongListSortOption(id: "new", name: "最新"),
        SongListSortOption(id: "hot", name: "最热"),
    ]

    let leaderboardBoards: [LeaderboardBoard] = [
        ("93", "飙升榜"), ("17", "新歌榜"), ("16", "热歌榜"), ("158", "抖音热歌榜"),
        ("292", "铃声榜"), ("284", "热评榜"), ("290", "ACG新歌榜"), ("286", "台湾KKBOX榜"),
        ("279", "冬日暖心榜"), ("281", "巴士随身听榜"), ("255", "KTV点唱榜"), ("280", "家务进行曲榜"),
        ("282", "熬夜修仙榜"), ("283", "枕边轻音乐榜"), ("278", "古风音乐榜"), ("264", "Vlog音乐榜"),
        ("242", "电音榜"), ("187", "流行趋势榜"), ("204", "现场音乐榜"), ("186", "ACG神曲榜"),
        ("185", "最强翻唱榜"), ("26", "经典怀旧榜"), ("104", "华语榜"), ("182", "粤语榜"),
        ("22", "欧美榜"), ("184", "韩语榜"), ("183", "日语榜"), ("145", "会员畅听榜"),
        ("153", "网红新歌榜"), ("64", "影视金曲榜"), ("176", "DJ嗨歌榜"), ("106", "真声音"),
        ("12", "Billboard榜"), ("49", "iTunes音乐榜"), ("180", "beatport电音榜"), ("13", "英国UK榜"),
        ("164", "百大DJ榜"), ("246", "YouTube音乐排行榜"), ("265", "韩国Genie榜"), ("14", "韩国M-net榜"),
        ("8", "香港电台榜"), ("15", "日本公信榜"), ("151", "腾讯音乐人原创榜"),
    ].map { LeaderboardBoard(id: "kw__\($0.0)", name: $0.1, bangid: $0.0, source: .kw) }

    // MARK: - Crypto Constants (`kw/util.js`)

    private static let wbdAesKey = Data([
        0x70, 0x57, 0x27, 0x3D, 0xC7, 0xFA, 0x29, 0xBF,
        0x39, 0x44, 0x2D, 0x72, 0xDD, 0x5E, 0x8C, 0xE4,
    ])
    private static let wbdAppId = "y67sprxhhpws"
    private static let lyricXorKey: [UInt8] = Array("yeelion".utf8)

    private func wbdBuildParam(_ jsonDict: [String: Any]) throws -> String {
        let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: [])
        let time = Int64(Date().timeIntervalSince1970 * 1000)
        let encrypted = try CryptoUtils.aesEncrypt(data: jsonData, key: Self.wbdAesKey, isECB: true)
        let encodedData = encrypted.base64EncodedString()
        let sign = CryptoUtils.md5Hex("\(Self.wbdAppId)\(encodedData)\(time)").uppercased()
        return "data=\(FormatUtils.urlEncodeComponent(encodedData))&time=\(time)&appId=\(Self.wbdAppId)&sign=\(sign)"
    }

    private func wbdDecodeData(_ rawString: String) throws -> [String: Any] {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        let unescaped = trimmed.removingPercentEncoding ?? trimmed
        guard let cipher = Data(base64Encoded: unescaped) else {
            throw MusicSDKError.parseError("KW wbd base64 decode failed")
        }
        let plain = try CryptoUtils.aesDecrypt(data: cipher, key: Self.wbdAesKey, isECB: true)
        guard let dict = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw MusicSDKError.parseError("KW wbd JSON parse failed")
        }
        return dict
    }

    private func formatSinger(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "、")
    }

    /// Converts Kuwo's single-quoted JS-object-like JSON into valid JSON (`objStr2JSON`).
    private func parseKuwoPseudoJSON(_ raw: String) throws -> [String: Any] {
        if let data = raw.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        var fixed = raw
        fixed = RegexHelper.replace(#"'(\s*[:,\}])"#, in: fixed, with: "\"$1")
        fixed = RegexHelper.replace(#"([:\{,]\s*)'"#, in: fixed, with: "$1\"")
        guard let data = fixed.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MusicSDKError.parseError("KW pseudo JSON parse failed")
        }
        return dict
    }

    private func parseMInfo(_ mInfo: String?, sortAscending: Bool = false) -> ([MusicQualityItem], [String: MusicQualityMeta]) {
        guard let mInfo, !mInfo.isEmpty else { return ([], [:]) }
        var types: [MusicQualityItem] = []
        var map: [String: MusicQualityMeta] = [:]
        var seenBitrates = Set<String>()

        for part in mInfo.split(separator: ";") {
            guard let m = RegexHelper.firstMatch(#"level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)"#, in: String(part)),
                  m.count >= 5 else { continue }
            let bitrate = m[2]
            if sortAscending && seenBitrates.contains(bitrate) { continue }
            seenBitrates.insert(bitrate)
            let rawSize = m[4]
            let upperSize = rawSize.uppercased()
            let quality: AudioQuality
            switch bitrate {
            case "4000": quality = .flac24bit
            case "2000": quality = .flac
            case "320": quality = .k320
            case "128": quality = .k128
            default: continue
            }
            types.append(MusicQualityItem(type: quality, size: sortAscending ? upperSize : rawSize))
            map[quality.rawValue] = MusicQualityMeta(size: upperSize)
        }

        if sortAscending {
            types.sort { $0.type.sortRank < $1.type.sortRank }
        } else {
            types.reverse()
        }
        return (types, map)
    }

    // MARK: - Search

    func searchMusic(query: String, page: Int, limit: Int = 30) async throws -> MusicSearchPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let encoded = FormatUtils.urlEncodeComponent(query)
            let url = "http://search.kuwo.cn/r.s?client=kt&all=\(encoded)&pn=\(max(0, page - 1))&rn=\(limit)&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1"
            let resp = try await HTTPClient.shared.get(url)
            let body = try resp.jsonDictionary()
            let totalStr = FormatUtils.stringValue(body["TOTAL"])
            let showStr = FormatUtils.stringValue(body["SHOW"])
            if totalStr != "0" && showStr == "0" {
                throw MusicSDKError.apiError("KW search returned empty SHOW")
            }
            let abslist = (body["abslist"] as? [[String: Any]]) ?? []
            var list: [MusicInfo] = []
            for info in abslist {
                guard let nMInfo = info["N_MINFO"] as? String else {
                    throw MusicSDKError.apiError("KW search missing N_MINFO")
                }
                let (types, map) = self.parseMInfo(nMInfo)
                let musicRid = FormatUtils.stringValue(info["MUSICRID"])
                let songmid = musicRid.replacingOccurrences(of: "MUSIC_", with: "")
                guard !songmid.isEmpty else { continue }

                let duration = FormatUtils.intValue(info["DURATION"])
                let interval = duration > 0 ? FormatUtils.formatPlayTime(duration) : nil
                let name = FormatUtils.decodeName(info["SONGNAME"] as? String)
                let singer = self.formatSinger(FormatUtils.decodeName(info["ARTIST"] as? String))
                let albumName = FormatUtils.decodeName(info["ALBUM"] as? String)
                let albumId = FormatUtils.decodeName(FormatUtils.stringValue(info["ALBUMID"]))

                list.append(MusicInfo(
                    id: "kw_\(songmid)",
                    name: name,
                    singer: singer,
                    source: .kw,
                    interval: interval,
                    meta: MusicMeta(
                        songId: songmid,
                        albumName: albumName,
                        picUrl: nil,
                        albumId: albumId,
                        qualitys: types,
                        _qualitys: map
                    )
                ))
            }
            let total = Int(totalStr) ?? list.count
            let allPage = max(1, Int(ceil(Double(total) / Double(max(1, limit)))))
            return MusicSearchPage(list: list, page: page, allPage: allPage, limit: limit, total: total, source: .kw)
        }
    }

    func getHotSearch() async throws -> [String] {
        let url = "http://hotword.kuwo.cn/hotword.s?prod=kwplayer_ar_9.3.0.1&corp=kuwo&newver=2&vipver=9.3.0.1&source=kwplayer_ar_9.3.0.1_40.apk&p2p=1&notrace=0&uid=0&plat=kwplayer_ar&rformat=json&encoding=utf8&tabid=1"
        let resp = try await HTTPClient.shared.get(url, headers: ["User-Agent": "Dalvik/2.1.0 (Linux; U; Android 9;)"])
        let body = try resp.jsonDictionary()
        guard resp.statusCode == 200, (body["status"] as? String) == "ok",
              let tagvalue = body["tagvalue"] as? [[String: Any]] else {
            throw MusicSDKError.apiError("获取酷我热搜词失败")
        }
        return tagvalue.compactMap { $0["key"] as? String }
    }

    func getTipSearch(query: String) async throws -> [String] {
        let url = "https://tips.kuwo.cn/t.s?corp=kuwo&newver=3&p2p=1&notrace=0&c=mbox&w=\(FormatUtils.urlEncodeComponent(query))&encoding=utf8&rformat=json"
        let resp = try await HTTPClient.shared.get(url, headers: ["Referer": "http://www.kuwo.cn/"])
        let body = try resp.jsonDictionary()
        guard resp.statusCode == 200, let items = body["WORDITEMS"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0["RELWORD"] as? String }
    }

    // MARK: - Leaderboard (`kw/leaderboard.js`)

    func getLeaderboardTracks(bangId: String, page: Int) async throws -> LeaderboardPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let limit = 100
            let payload: [String: Any] = [
                "uid": "",
                "devId": "",
                "sFrom": "kuwo_sdk",
                "user_type": "AP",
                "carSource": "kwplayercar_ar_6.0.1.0_apk_keluze.apk",
                "id": bangId,
                "pn": max(0, page - 1),
                "rn": limit,
            ]
            let query = try self.wbdBuildParam(payload)
            let url = "https://wbd.kuwo.cn/api/bd/bang/bang_info?\(query)"
            let resp = try await HTTPClient.shared.get(url)
            guard resp.statusCode == 200 else {
                throw MusicSDKError.httpStatus(resp.statusCode, "KW leaderboard error")
            }
            let rawData = try self.wbdDecodeData(resp.text)
            guard FormatUtils.intValue(rawData["code"]) == 200,
                  let data = rawData["data"] as? [String: Any],
                  let musicList = data["musiclist"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("KW leaderboard invalid data")
            }

            let list: [MusicInfo] = musicList.compactMap { item in
                let songmid = FormatUtils.stringValue(item["id"])
                guard !songmid.isEmpty else { return nil }
                let (types, map) = self.parseMInfo(item["n_minfo"] as? String, sortAscending: true)
                let duration = FormatUtils.intValue(item["duration"])
                return MusicInfo(
                    id: "kw_\(songmid)",
                    name: FormatUtils.decodeName(item["name"] as? String),
                    singer: self.formatSinger(FormatUtils.decodeName(item["artist"] as? String)),
                    source: .kw,
                    interval: FormatUtils.formatPlayTime(duration),
                    meta: MusicMeta(
                        songId: songmid,
                        albumName: FormatUtils.decodeName(item["album"] as? String),
                        picUrl: item["pic"] as? String,
                        albumId: FormatUtils.stringValue(item["albumId"]),
                        qualitys: types,
                        _qualitys: map
                    )
                )
            }
            let total = FormatUtils.intValue(data["total"])
            return LeaderboardPage(list: list, page: page, limit: limit, total: total > 0 ? total : list.count, source: .kw)
        }
    }

    // MARK: - SongList (`kw/songList.js`)

    func getSongListTags() async throws -> SongListTagsResult {
        async let tagGroupsTask = fetchSongListTagGroups()
        async let hotTagsTask = fetchSongListHotTags()
        let (groups, hotTags) = try await (tagGroupsTask, hotTagsTask)
        return SongListTagsResult(hotTag: hotTags, tags: groups, source: .kw)
    }

    private func fetchSongListTagGroups() async throws -> [SongListTagGroup] {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let url = "http://wapi.kuwo.cn/api/pc/classify/playlist/getTagList?cmd=rcm_keyword_playlist&user=0&prod=kwplayer_pc_9.0.5.0&vipver=9.0.5.0&source=kwplayer_pc_9.0.5.0&loginUid=0&loginSid=0&appUid=76039576"
            let resp = try await HTTPClient.shared.get(url)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["code"]) == 200, let data = body["data"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("KW getTagList failed")
            }
            return data.map { group in
                let gName = FormatUtils.stringValue(group["name"])
                let gId = FormatUtils.stringValue(group["id"])
                let items = (group["data"] as? [[String: Any]]) ?? []
                return SongListTagGroup(
                    name: gName,
                    list: items.map { item in
                        SongListTagItem(
                            id: "\(FormatUtils.stringValue(item["id"]))-\(FormatUtils.stringValue(item["digest"]))",
                            name: FormatUtils.stringValue(item["name"]),
                            parentId: gId,
                            parentName: gName,
                            source: .kw
                        )
                    }
                )
            }
        }
    }

    private func fetchSongListHotTags() async throws -> [SongListTagItem] {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let url = "http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmTagList?loginUid=0&loginSid=0&appUid=76039576"
            let resp = try await HTTPClient.shared.get(url)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["code"]) == 200,
                  let data = body["data"] as? [[String: Any]],
                  let first = data.first,
                  let items = first["data"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("KW getRcmTagList failed")
            }
            return items.map { item in
                SongListTagItem(
                    id: "\(FormatUtils.stringValue(item["id"]))-\(FormatUtils.stringValue(item["digest"]))",
                    name: FormatUtils.stringValue(item["name"]),
                    source: .kw
                )
            }
        }
    }

    func getSongList(sortId: String, tagId: String?, page: Int) async throws -> SongListSearchPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let limit = 36
            var parsedId: String?
            var parsedType: String?
            if let tagId, !tagId.isEmpty {
                let parts = tagId.split(separator: "-")
                if parts.count >= 2 {
                    parsedId = String(parts[0])
                    parsedType = String(parts[1])
                }
            }

            if parsedType == "43", let id = parsedId {
                let url = "http://mobileinterfaces.kuwo.cn/er.s?type=get_pc_qz_data&f=web&id=\(id)&prod=pc"
                let resp = try await HTTPClient.shared.get(url)
                let arr = try resp.jsonArray()
                var items: [OnlineSongListItem] = []
                for section in arr {
                    guard let dict = section as? [String: Any],
                          let list = dict["list"] as? [[String: Any]] else { continue }
                    for item in list {
                        let itemType = FormatUtils.stringValue(item["type"])
                        guard itemType == "songlist" || itemType == "list" || itemType == "album" else { continue }
                        let digest = FormatUtils.stringValue(item["digest"])
                        let itemId = FormatUtils.stringValue(item["id"])
                        let listenCnt = FormatUtils.int64Value(item["listencnt"])
                        items.append(OnlineSongListItem(
                            id: "digest-\(digest)__\(itemId)",
                            name: FormatUtils.decodeName(item["name"] as? String),
                            author: FormatUtils.decodeName(item["uname"] as? String),
                            img: item["img"] as? String,
                            playCount: listenCnt > 0 ? FormatUtils.formatPlayCount(listenCnt) : nil,
                            desc: FormatUtils.decodeName(item["desc"] as? String),
                            total: FormatUtils.intValue(item["total"]),
                            source: .kw
                        ))
                    }
                }
                return SongListSearchPage(list: items, page: page, limit: 1000, total: items.count, source: .kw)
            }

            let url: String
            if let id = parsedId, parsedType == "10000" {
                url = "http://wapi.kuwo.cn/api/pc/classify/playlist/getTagPlayList?loginUid=0&loginSid=0&appUid=76039576&pn=\(page)&id=\(id)&rn=\(limit)"
            } else {
                url = "http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList?loginUid=0&loginSid=0&appUid=76039576&&pn=\(page)&rn=\(limit)&order=\(sortId)"
            }

            let resp = try await HTTPClient.shared.get(url)
            let body = try resp.jsonDictionary()
            guard FormatUtils.intValue(body["code"]) == 200,
                  let data = body["data"] as? [String: Any],
                  let rawList = data["data"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("KW getSongList failed")
            }

            let items = rawList.map { item -> OnlineSongListItem in
                let digest = FormatUtils.stringValue(item["digest"])
                let itemId = FormatUtils.stringValue(item["id"])
                let listenCnt = FormatUtils.int64Value(item["listencnt"])
                return OnlineSongListItem(
                    id: "digest-\(digest)__\(itemId)",
                    name: FormatUtils.decodeName(item["name"] as? String),
                    author: FormatUtils.decodeName(item["uname"] as? String),
                    img: item["img"] as? String,
                    playCount: FormatUtils.formatPlayCount(listenCnt),
                    desc: FormatUtils.decodeName(item["desc"] as? String),
                    total: FormatUtils.intValue(item["total"]),
                    source: .kw
                )
            }
            return SongListSearchPage(
                list: items,
                page: FormatUtils.intValue(data["pn"]),
                limit: FormatUtils.intValue(data["rn"]),
                total: FormatUtils.intValue(data["total"]),
                source: .kw
            )
        }
    }

    func searchSongList(query: String, page: Int, limit: Int = 20) async throws -> SongListSearchPage {
        let encoded = FormatUtils.urlEncodeComponent(query)
        let url = "http://search.kuwo.cn/r.s?all=\(encoded)&pn=\(max(0, page - 1))&rn=\(limit)&rformat=json&encoding=utf8&ver=mbox&vipver=MUSIC_8.7.7.0_BCS37&plat=pc&devid=28156413&ft=playlist&pay=0&needliveshow=0"
        let resp = try await HTTPClient.shared.get(url)
        let body = try parseKuwoPseudoJSON(resp.text)
        let abslist = (body["abslist"] as? [[String: Any]]) ?? []
        let list = abslist.map { item -> OnlineSongListItem in
            OnlineSongListItem(
                id: FormatUtils.stringValue(item["playlistid"]),
                name: FormatUtils.decodeName(item["name"] as? String),
                author: FormatUtils.decodeName(item["nickname"] as? String),
                img: item["pic"] as? String,
                playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(item["playcnt"])),
                desc: FormatUtils.decodeName(item["intro"] as? String),
                total: FormatUtils.intValue(item["songnum"]),
                source: .kw
            )
        }
        let total = FormatUtils.intValue(body["TOTAL"])
        return SongListSearchPage(list: list, page: page, limit: limit, total: total, source: .kw)
    }

    func getSongListDetail(idOrUrl: String, page: Int) async throws -> SongListDetailPage {
        var id = idOrUrl.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Bodian playlist URL
        if id.contains("/bodian/") {
            return try await fetchBodianSongList(url: id, page: page)
        }

        // 2. Kuwo web/mobile URL
        if RegexHelper.test(#"[?&:/]"#, in: id) {
            if let m = RegexHelper.firstMatch(#"/playlist(?:_detail)?/(\d+)"#, in: id), m.count >= 2 {
                id = m[1]
            }
        }

        // 3. Digest-prefixed ID
        if id.hasPrefix("digest-") {
            let parts = id.components(separatedBy: "__")
            if parts.count >= 2 {
                let digest = parts[0].replacingOccurrences(of: "digest-", with: "")
                let rawId = parts[1]
                switch digest {
                case "13":
                    return try await fetchAlbumDetail(albumId: rawId, page: page)
                case "5":
                    return try await fetchDigest5Detail(nodeId: rawId, page: page)
                default:
                    id = rawId
                }
            }
        }

        // 4. Default Digest 8
        return try await fetchDigest8Detail(pid: id, page: page)
    }

    private func fetchDigest8Detail(pid: String, page: Int) async throws -> SongListDetailPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let url = "http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=\(pid)&pn=\(max(0, page - 1))&rn=1000&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1"
            let resp = try await HTTPClient.shared.get(url)
            let body = try resp.jsonDictionary()
            guard (body["result"] as? String) == "ok" else {
                throw MusicSDKError.apiError("KW playlist detail failed")
            }
            let rawList = (body["musiclist"] as? [[String: Any]]) ?? []
            let list = self.parsePlaylistTracks(rawList)
            let info = OnlineSongListInfo(
                name: FormatUtils.decodeName(body["title"] as? String),
                img: body["pic"] as? String,
                desc: FormatUtils.decodeName(body["info"] as? String),
                author: FormatUtils.decodeName(body["uname"] as? String),
                playCount: FormatUtils.formatPlayCount(FormatUtils.int64Value(body["playnum"]))
            )
            return SongListDetailPage(
                list: list,
                page: page,
                limit: FormatUtils.intValue(body["rn"]),
                total: FormatUtils.intValue(body["total"]),
                source: .kw,
                info: info
            )
        }
    }

    private func fetchDigest5Detail(nodeId: String, page: Int) async throws -> SongListDetailPage {
        let infoUrl = "http://qukudata.kuwo.cn/q.k?op=query&cont=ninfo&node=\(nodeId)&pn=0&rn=1&fmt=json&src=mbox&level=2"
        let infoResp = try await HTTPClient.shared.get(infoUrl)
        let infoBody = try infoResp.jsonDictionary()
        guard let children = infoBody["child"] as? [[String: Any]],
              let first = children.first else {
            throw MusicSDKError.apiError("KW digest5 playlist not found")
        }
        let detailId = FormatUtils.stringValue(first["sourceid"])
        return try await fetchDigest8Detail(pid: detailId, page: page)
    }

    private func fetchAlbumDetail(albumId: String, page: Int) async throws -> SongListDetailPage {
        try await HTTPClient.withRetry(maxAttempts: 3) {
            let url = "http://search.kuwo.cn/r.s?pn=\(max(0, page - 1))&rn=1000&stype=albuminfo&albumid=\(albumId)&show_copyright_off=0&encoding=utf&vipver=MUSIC_9.1.0"
            let resp = try await HTTPClient.shared.get(url)
            let body = try self.parseKuwoPseudoJSON(resp.text)
            guard let musiclist = body["musiclist"] as? [[String: Any]] else {
                throw MusicSDKError.apiError("KW album detail missing musiclist")
            }
            let albumName = FormatUtils.decodeName(body["name"] as? String)
            let list: [MusicInfo] = musiclist.compactMap { item in
                let songmid = FormatUtils.stringValue(item["id"])
                guard !songmid.isEmpty else { return nil }
                var types: [MusicQualityItem] = []
                var map: [String: MusicQualityMeta] = [:]
                let formats = FormatUtils.stringValue(item["formats"]).split(separator: "|")
                for fmt in formats {
                    let q: AudioQuality
                    switch fmt {
                    case "MP3128": q = .k128
                    case "MP3H": q = .k320
                    case "ALFLAC": q = .flac
                    case "HIRFLAC": q = .flac24bit
                    default: continue
                    }
                    types.append(MusicQualityItem(type: q, size: nil))
                    map[q.rawValue] = MusicQualityMeta(size: nil)
                }
                return MusicInfo(
                    id: "kw_\(songmid)",
                    name: FormatUtils.decodeName(item["name"] as? String),
                    singer: self.formatSinger(FormatUtils.decodeName(item["artist"] as? String)),
                    source: .kw,
                    interval: nil,
                    meta: MusicMeta(
                        songId: songmid,
                        albumName: albumName,
                        picUrl: item["pic"] as? String,
                        albumId: FormatUtils.stringValue(body["albumid"]),
                        qualitys: types,
                        _qualitys: map
                    )
                )
            }
            let info = OnlineSongListInfo(
                name: albumName,
                img: (body["img"] as? String) ?? (body["hts_img"] as? String),
                desc: FormatUtils.decodeName(body["info"] as? String),
                author: FormatUtils.decodeName(body["artist"] as? String),
                playCount: nil
            )
            return SongListDetailPage(
                list: list,
                page: page,
                limit: 1000,
                total: FormatUtils.intValue(body["songnum"]),
                source: .kw,
                info: info
            )
        }
    }

    private func fetchBodianSongList(url: String, page: Int) async throws -> SongListDetailPage {
        guard let listId = RegexHelper.firstMatch(#"playlistId=(\d+)"#, in: url)?[1], !listId.isEmpty else {
            throw MusicSDKError.parseError("无法解析波点歌单 ID")
        }
        let uid = RegexHelper.firstMatch(#"uid=(\d+)"#, in: url)?[1]
        let src = RegexHelper.firstMatch(#"source=(\d+)"#, in: url)?[1] ?? "4"
        let reqId = CryptoUtils.randomBytes(16).hexLowercased
        let headers = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36",
            "plat": "h5",
        ]

        let listUrl = "https://bd-api.kuwo.cn/api/service/playlist/\(listId)/musicList?reqId=\(reqId)&source=\(src)&pn=\(page)&rn=1000"
        let resp = try await HTTPClient.shared.get(listUrl, headers: headers)
        let body = try resp.jsonDictionary()
        guard FormatUtils.intValue(body["code"]) == 200,
              let data = body["data"] as? [String: Any],
              let rawList = data["list"] as? [[String: Any]] else {
            throw MusicSDKError.apiError("获取波点歌单失败")
        }

        let list: [MusicInfo] = rawList.compactMap { item in
            let songmid = FormatUtils.stringValue(item["id"])
            guard !songmid.isEmpty else { return nil }
            var types: [MusicQualityItem] = []
            var map: [String: MusicQualityMeta] = [:]
            if let audios = item["audios"] as? [[String: Any]] {
                for audio in audios {
                    let bitrate = FormatUtils.stringValue(audio["bitrate"])
                    let size = (audio["size"] as? String)?.uppercased()
                    let q: AudioQuality
                    switch bitrate {
                    case "4000": q = .flac24bit
                    case "2000": q = .flac
                    case "320": q = .k320
                    case "128": q = .k128
                    default: continue
                    }
                    types.append(MusicQualityItem(type: q, size: size))
                    map[q.rawValue] = MusicQualityMeta(size: size)
                }
            }
            types.reverse()
            let artists = (item["artists"] as? [[String: Any]]) ?? []
            return MusicInfo(
                id: "kw_\(songmid)",
                name: FormatUtils.decodeName(item["name"] as? String),
                singer: FormatUtils.formatSingerName(artists, nameKey: "name"),
                source: .kw,
                interval: FormatUtils.formatPlayTime(FormatUtils.intValue(item["duration"])),
                meta: MusicMeta(
                    songId: songmid,
                    albumName: FormatUtils.decodeName(item["album"] as? String),
                    picUrl: item["albumPic"] as? String,
                    albumId: FormatUtils.stringValue(item["albumId"]),
                    qualitys: types,
                    _qualitys: map
                )
            )
        }

        var info = OnlineSongListInfo(name: "波点歌单", img: nil, desc: nil, author: nil, playCount: nil)
        if src == "4" {
            if let r = try? await HTTPClient.shared.get("https://bd-api.kuwo.cn/api/service/playlist/info/\(listId)?reqId=\(reqId)&source=\(src)", headers: headers),
               let d = (try? r.jsonDictionary())?["data"] as? [String: Any] {
                info = OnlineSongListInfo(
                    name: FormatUtils.stringValue(d["name"]),
                    img: d["pic"] as? String,
                    desc: d["description"] as? String,
                    author: d["creatorName"] as? String,
                    playCount: FormatUtils.stringValue(d["playNum"])
                )
            }
        } else if src == "5" {
            let targetUid = uid ?? listId
            if let r = try? await HTTPClient.shared.get("https://bd-api.kuwo.cn/api/ucenter/users/pub/\(targetUid)?reqId=\(reqId)", headers: headers),
               let d = (try? r.jsonDictionary())?["data"] as? [String: Any],
               let u = d["userInfo"] as? [String: Any] {
                let nick = FormatUtils.stringValue(u["nickname"])
                info = OnlineSongListInfo(
                    name: "\(nick)喜欢的音乐",
                    img: u["headImg"] as? String,
                    desc: nil,
                    author: nick,
                    playCount: nil
                )
            }
        }

        return SongListDetailPage(
            list: list,
            page: page,
            limit: FormatUtils.intValue(data["pageSize"]),
            total: FormatUtils.intValue(data["total"]),
            source: .kw,
            info: info
        )
    }

    private func parsePlaylistTracks(_ rawList: [[String: Any]]) -> [MusicInfo] {
        rawList.compactMap { item in
            let songmid = FormatUtils.stringValue(item["id"])
            guard !songmid.isEmpty else { return nil }
            let (types, map) = parseMInfo(item["N_MINFO"] as? String)
            return MusicInfo(
                id: "kw_\(songmid)",
                name: FormatUtils.decodeName(item["name"] as? String),
                singer: formatSinger(FormatUtils.decodeName(item["artist"] as? String)),
                source: .kw,
                interval: FormatUtils.formatPlayTime(FormatUtils.intValue(item["duration"])),
                meta: MusicMeta(
                    songId: songmid,
                    albumName: FormatUtils.decodeName(item["album"] as? String),
                    picUrl: nil,
                    albumId: FormatUtils.stringValue(item["albumid"]),
                    qualitys: types,
                    _qualitys: map
                )
            )
        }
    }

    // MARK: - Pic (`kw/pic.js`)

    func getPic(musicInfo: MusicInfo) async throws -> String {
        let url = "http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid=\(musicInfo.meta.songId)"
        let resp = try await HTTPClient.shared.get(url)
        let text = resp.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("http") else {
            throw MusicSDKError.picNotFound
        }
        return text
    }

    // MARK: - Lyric (`kw/lyric.js` + `kw/util.js`)

    func getLyric(musicInfo: MusicInfo) async throws -> LyricInfo {
        let url = "http://mlyric.kuwo.cn/mobi.s?f=web&type=lyric&lrcx=1&rid=\(musicInfo.meta.songId)&encode=utf8"
        let resp = try await HTTPClient.shared.get(url)
        guard resp.statusCode == 200 else {
            throw MusicSDKError.lyricNotFound
        }
        let decoded = try Self.decodeLyricData(resp.data, isGetLyricx: true)
        guard !decoded.isEmpty else { throw MusicSDKError.lyricNotFound }
        return try Self.parseKuwoLyricText(decoded)
    }

    /// Exact port of `kw/util.js:decodeLyric` (zlib inflate + base64 decode + `'yeelion'` XOR).
    static func decodeLyricData(_ rawData: Data, isGetLyricx: Bool) throws -> String {
        guard rawData.count > 10 else { return "" }
        let prefix = String(data: rawData.prefix(10), encoding: .utf8)?.lowercased() ?? ""
        guard prefix == "tp=content" else { return "" }

        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = rawData.range(of: sep) else { return "" }
        let compressed = rawData[range.upperBound...]
        let inflated = try CryptoUtils.zlibInflate(Data(compressed))

        guard isGetLyricx else {
            return String(data: inflated, encoding: .utf8) ?? String(decoding: inflated, as: UTF8.self)
        }

        let b64String = (String(data: inflated, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let b64Data = Data(base64Encoded: b64String, options: .ignoreUnknownCharacters) else {
            return ""
        }
        var bytes = [UInt8](b64Data)
        let keyLen = lyricXorKey.count
        for i in 0..<bytes.count {
            bytes[i] ^= lyricXorKey[i % keyLen]
        }
        return String(data: Data(bytes), encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Exact port of `kw/lyric.js:parseLrc` + `kw/util.js:lrcTools.parse`.
    static func parseKuwoLyricText(_ rawText: String) throws -> LyricInfo {
        let lines = rawText.components(separatedBy: CharacterSet.newlines)
        var tags: [String] = []
        var lrcArr: [(time: String, text: String)] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let m = RegexHelper.firstMatch(#"^\[([\d:.]*)\]"#, in: line), m.count >= 2 {
                var time = m[1]
                if RegexHelper.test(#"\.\d\d$"#, in: time) {
                    time += "0"
                }
                let text = String(line.dropFirst(m[0].count)).trimmingCharacters(in: .whitespaces)
                lrcArr.append((time: time, text: text))
            } else if RegexHelper.test(#"\[(ver|ti|ar|al|offset|by|kuwo):\s*(\S+(?:\s+\S+)*)\s*\]"#, in: line) {
                tags.append(line)
            }
        }

        // Separate interleaved Kuwo translation lines (`sortLrcArr`)
        var lrcSet = Set<String>()
        var mainLrc: [(time: String, text: String)] = []
        var transLrc: [(time: String, text: String)] = []
        var isLyricx = false

        for item in lrcArr {
            if lrcSet.contains(item.time) {
                if mainLrc.count < 2 { continue }
                var tItem = mainLrc.removeLast()
                tItem.time = mainLrc[mainLrc.count - 1].time
                transLrc.append(tItem)
                mainLrc.append(item)
            } else {
                mainLrc.append(item)
                lrcSet.insert(item.time)
            }
            if !isLyricx && RegexHelper.test(#"^<-?\d+,-?\d+>"#, in: item.text) {
                isLyricx = true
            }
        }

        if !isLyricx && Double(transLrc.count) > Double(mainLrc.count) * 0.3 && (mainLrc.count - transLrc.count) > 6 {
            throw MusicSDKError.lyricNotFound
        }

        func assemble(_ list: [(time: String, text: String)]) -> String {
            let header = tags.joined(separator: "\n")
            let body = list.map { "[\($0.time)]\($0.text)" }.joined(separator: "\n")
            return header.isEmpty ? body : "\(header)\n\(body)"
        }

        let rawMain = FormatUtils.decodeLyricEntities(assemble(mainLrc))
        var tlyric = transLrc.isEmpty ? "" : FormatUtils.decodeLyricEntities(assemble(transLrc))
        let wordTagPattern = #"<(-?\d+),(-?\d+)(?:,-?\d+)?>"#

        if !tlyric.isEmpty {
            tlyric = RegexHelper.replace(wordTagPattern, in: tlyric, with: "")
        }
        let lxlyric = parseKuwoWordLyric(rawMain)
        let plainLyric = RegexHelper.replace(wordTagPattern, in: rawMain, with: "")

        guard RegexHelper.test(#"\[\d{1,2}:.*\d{1,4}\]"#, in: plainLyric) else {
            throw MusicSDKError.lyricNotFound
        }
        return LyricInfo(lyric: plainLyric, tlyric: tlyric, lxlyric: lxlyric)
    }

    /// Exact port of `kw/util.js:lrcTools.parse` (octal `[kuwo:...]` key decoding for `<o1,o2>` tags).
    static func parseKuwoWordLyric(_ lyric: String) -> String {
        var offset = 1
        var offset2 = 1
        var outLines: [String] = []
        var outTags: [String] = []

        for rawLine in lyric.components(separatedBy: CharacterSet.newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count >= 6 else { continue }

            if let m = RegexHelper.firstMatch(#"^(\[\d{1,2}:.*\d{1,4}\])\s*(\S+(?:\s+\S+)*)?"#, in: line), m.count >= 2 {
                let timePrefix = m[1]
                var words = m.count >= 3 ? m[2] : ""
                let wordMatches = RegexHelper.allMatches(#"<(-?\d+),(-?\d+)(?:,-?\d+)?>"#, in: words)
                guard !wordMatches.isEmpty else { continue }

                struct WordInfo {
                    var startTime: Int
                    var endTime: Int
                    var timeStr: String
                    var newTimeStr: String?
                }

                var prev: WordInfo?
                for wm in wordMatches {
                    guard wm.count >= 3, let o1 = Int(wm[1]), let o2 = Int(wm[2]) else { continue }
                    let startTime = Int(trunc(abs(Double(o1 + o2) / Double(offset * 2))))
                    let endTime = Int(trunc(abs(Double(o1 - o2) / Double(offset2 * 2)) + Double(startTime)))

                    if var p = prev, startTime < p.endTime {
                        p.endTime = startTime
                        if p.startTime > p.endTime { p.startTime = p.endTime }
                        p.newTimeStr = "<\(p.startTime),\(p.endTime - p.startTime)>"
                        prev = p
                    }

                    let cur = WordInfo(
                        startTime: startTime,
                        endTime: endTime,
                        timeStr: "<\(startTime),\(endTime - startTime)>"
                    )
                    if let r = words.range(of: wm[0]) {
                        words.replaceSubrange(r, with: cur.timeStr)
                    }
                    if let p = prev, let newStr = p.newTimeStr, let pr = words.range(of: p.timeStr) {
                        words.replaceSubrange(pr, with: newStr)
                    }
                    prev = cur
                }
                outLines.append(timePrefix + words)
            } else if let tm = RegexHelper.firstMatch(#"\[(ver|ti|ar|al|offset|by|kuwo):\s*(\S+(?:\s+\S+)*)\s*\]"#, in: line), tm.count >= 3 {
                if tm[1] == "kuwo" {
                    var content = tm[2]
                    if let sepRange = content.range(of: "][") {
                        content = String(content[..<sepRange.lowerBound])
                    }
                    guard let octalVal = Int(content, radix: 8) else { return "" }
                    offset = octalVal / 10
                    offset2 = octalVal % 10
                    if offset == 0 || offset2 == 0 { return "" }
                } else {
                    outTags.append(line)
                }
            }
        }

        guard !outLines.isEmpty else { return "" }
        if outTags.isEmpty { return outLines.joined(separator: "\n") }
        return "\(outTags.joined(separator: "\n"))\n\(outLines.joined(separator: "\n"))"
    }
}
