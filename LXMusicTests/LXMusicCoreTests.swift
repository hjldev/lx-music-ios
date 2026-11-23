import XCTest
@testable import LXMusic

final class LXMusicCoreTests: XCTestCase {

    // MARK: - 1. Crypto & Signatures

    func testTXZzcSignSafeIndex40() {
        let input = "{\"comm\":{\"ct\":\"19\",\"uin\":\"0\"}}"
        let sign = TXMusicSDK.zzcSign(input)
        XCTAssertTrue(sign.hasPrefix("zzc"))
        XCTAssertEqual(sign, sign.lowercased())
        // zzc (3) + part1 (7 chars, index 40 omitted!) + b64Part (<=27 chars) + part2 (8 chars)
        XCTAssertGreaterThan(sign.count, 25)
    }

    func testWYEapiAndLinuxapiCrypto() throws {
        let eapiForm = try WYMusicSDK.eapi(url: "/api/song/lyric/v1", object: ["id": "12345"])
        XCTAssertNotNil(eapiForm["params"])
        XCTAssertEqual(eapiForm["params"], eapiForm["params"]?.uppercased())

        let linuxForm = try WYMusicSDK.linuxapi(["method": "POST", "url": "https://music.163.com/api/v3/playlist/detail"])
        XCTAssertNotNil(linuxForm["eparams"])

        let weapiForm = try WYMusicSDK.weapi(["s": "周杰伦"])
        XCTAssertFalse((weapiForm["params"] ?? "").isEmpty)
        XCTAssertEqual(weapiForm["encSecKey"]?.count, 256)
    }

    func testKGAndMGSignatures() {
        let kgSig = KGMusicSDK.signatureParams("appid=1058&page=1", platform: "web")
        XCTAssertEqual(kgSig.count, 32)
        let infSig = KGMusicSDK.infSignPlaylist(specialId: "12345", page: 1, limit: 100)
        XCTAssertEqual(infSig.count, 32)
        let mgSig = MGMusicSDK.createSignature(time: "1700000000000", query: "稻香")
        XCTAssertEqual(mgSig.count, 32)
    }

    func testZlibAndGzipRoundTrip() throws {
        let original = Data("Hello LX Music 原生 iOS 应用! 🎵".utf8)
        let deflated = try CryptoUtils.zlibDeflate(original)
        let inflated = try CryptoUtils.zlibInflate(deflated)
        XCTAssertEqual(inflated, original)

        let gzipped = try CryptoUtils.gzipCompress(original)
        XCTAssertEqual(gzipped.prefix(2), Data([0x1F, 0x8B]))
        let gunzipped = try CryptoUtils.gunzipDecompress(gzipped)
        XCTAssertEqual(gunzipped, original)
    }

    // MARK: - 2. Lyric Parsing & Karaoke Word Timing

    func testLyricParserWordByWordAndAlignment() {
        let info = LyricInfo(
            lyric: "[00:01.000]你好世界\n[00:05.000]第二行",
            tlyric: "[00:01.000]Hello World\n[00:05.000]//",
            lxlyric: "[offset:100]\n[00:01.000]<0,400>你好<400,600>世界\n[00:05.000]<0,500>第二行"
        )
        let doc = LyricParser.parse(
            info: info,
            showTranslation: true,
            playWordByWord: true
        )
        XCTAssertTrue(doc.isWordMode)
        XCTAssertEqual(doc.offsetMs, 100)
        XCTAssertEqual(doc.lines.count, 2)
        XCTAssertEqual(doc.lines[0].text, "你好世界")
        XCTAssertEqual(doc.lines[0].words.count, 2)
        XCTAssertEqual(doc.lines[0].extendedLyrics, ["Hello World"])
        // "//" placeholder translation line must be ignored
        XCTAssertTrue(doc.lines[1].extendedLyrics.isEmpty)

        // Active line & word progress check
        XCTAssertEqual(LyricParser.activeLineIndex(in: doc, atMs: 1200), 0)
        XCTAssertEqual(LyricParser.activeLineIndex(in: doc, atMs: 5200), 1)
        let progress = LyricParser.wordProgress(line: doc.lines[0], word: doc.lines[0].words[0], atMs: 1100, offsetMs: doc.effectiveOffsetMs)
        XCTAssertEqual(progress, 0.5, accuracy: 0.01)
    }

    func testKGKRCDecode() throws {
        // Synthesize a valid KRC payload: "krc1" + XOR(zlib(krcText), krcKey)
        let langJSON = "{\"content\":[{\"type\":1,\"lyricContent\":[[\"Hello\"]]}]}"
        let langB64 = Data(langJSON.utf8).base64EncodedString()
        let krcText = "[id:$00000000]\n[language:\(langB64)]\n[1000,2000]<0,500,0>你好"
        let compressed = try CryptoUtils.zlibDeflate(Data(krcText.utf8))
        let krcKey: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69]
        var xored = [UInt8](compressed)
        for i in 0..<xored.count { xored[i] ^= krcKey[i % 16] }
        let payload = Data("krc1".utf8) + Data(xored)

        let decoded = try KGMusicSDK.decodeKRC(base64Content: payload.base64EncodedString())
        XCTAssertTrue(decoded.lyric.contains("[00:01.000]你好"))
        XCTAssertTrue((decoded.lxlyric ?? "").contains("<0,500>你好"))
        XCTAssertTrue((decoded.tlyric ?? "").contains("[00:01.000]Hello"))
    }

    // MARK: - 3. Cross-Source Matching (`findMusic`) & Quality Downgrade

    func testMusicMatcherVersionGuardAndRanking() {
        let target = MusicInfo(
            id: "wy_1",
            name: "稻香",
            singer: "周杰伦",
            source: .wy,
            interval: "03:43",
            meta: MusicMeta(songId: "1", albumName: "魔杰座")
        )
        let liveTrack = MusicInfo(
            id: "kw_live",
            name: "稻香 (Live)",
            singer: "周杰伦",
            source: .kw,
            interval: "03:44",
            meta: MusicMeta(songId: "live", albumName: "演唱会")
        )
        let exactMatch = MusicInfo(
            id: "tx_exact",
            name: "稻香",
            singer: "周杰伦",
            source: .tx,
            interval: "03:43",
            meta: MusicMeta(songId: "exact", albumName: "魔杰座")
        )

        let ranked = MusicMatcher.rankCandidates(target: target, candidateLists: [[liveTrack], [exactMatch]])
        XCTAssertEqual(ranked.map(\.id), ["tx_exact"])
    }

    func testQualityDowngradeOrder() {
        let track = MusicInfo(
            id: "wy_1",
            name: "Song",
            singer: "Artist",
            source: .wy,
            meta: MusicMeta(
                songId: "1",
                qualitys: [
                    MusicQualityItem(type: .k128, size: "3.5M"),
                    MusicQualityItem(type: .k320, size: "8.9M"),
                ]
            )
        )
        let chosen = MusicMatcher.resolvePlayQuality(
            preferred: .flac24bit,
            musicInfo: track,
            supportedBySource: [.k128, .k320, .flac]
        )
        XCTAssertEqual(chosen, .k320)
    }

    // MARK: - 4. Dislike Rules (`@` separator & `#` alias)

    @MainActor
    func testDislikeStoreRulesAndAliasEscape() {
        let store = DislikeStore()
        store.updateRules("BadSong@Artist\nOnlySong\n@BlockedSinger\nA#B@Singer")

        let exact = MusicInfo(id: "1", name: "badsong", singer: "artist", source: .wy, meta: MusicMeta(songId: "1"))
        let bySong = MusicInfo(id: "2", name: "OnlySong", singer: "Anyone", source: .wy, meta: MusicMeta(songId: "2"))
        let bySinger = MusicInfo(id: "3", name: "Random", singer: "BlockedSinger", source: .wy, meta: MusicMeta(songId: "3"))
        let withAtSign = MusicInfo(id: "4", name: "A@B", singer: "Singer", source: .wy, meta: MusicMeta(songId: "4"))
        let ok = MusicInfo(id: "5", name: "GoodSong", singer: "GoodSinger", source: .wy, meta: MusicMeta(songId: "5"))

        XCTAssertTrue(store.hasDislike(exact))
        XCTAssertTrue(store.hasDislike(bySong))
        XCTAssertTrue(store.hasDislike(bySinger))
        XCTAssertTrue(store.hasDislike(withAtSign))
        XCTAssertFalse(store.hasDislike(ok))
    }

    // MARK: - 5. Custom Source Header Parser & JavaScriptCore Engine

    func testUserApiHeaderParser() throws {
        let script = """
        /**
         * @name Test LX Source
         * @description Unit test custom source
         * @version 1.2.3
         * @author Tester
         * @homepage https://example.com
         */
        """
        let parsed = try UserApiHeaderParser.parse(script)
        XCTAssertEqual(parsed.name, "Test LX Source")
        XCTAssertEqual(parsed.version, "1.2.3")
        XCTAssertEqual(parsed.author, "Tester")
    }

    func testUserApiEngineJavaScriptCoreExecution() async throws {
        let scriptCode = """
        /**
         * @name Mock Source
         * @version 1.0.0
         */
        const { EVENT_NAMES, on, send, utils } = globalThis.lx;
        on(EVENT_NAMES.request, ({ source, action, info }) => {
          const hash = utils.crypto.md5(source + '_' + info.musicInfo.songmid + '_' + info.type);
          return Promise.resolve('https://cdn.example.com/' + hash + '.mp3');
        });
        send(EVENT_NAMES.inited, {
          status: true,
          sources: {
            wy: { type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] }
          }
        });
        """

        let engine = UserApiEngine()
        let initedExpectation = expectation(description: "Script initialized")
        var didFulfill = false
        engine.onStatusChange = { status in
            if status.isInitialized && !didFulfill {
                didFulfill = true
                initedExpectation.fulfill()
            }
        }

        let script = UserApiScript(id: "test_1", name: "Mock Source", script: scriptCode)
        engine.load(script: script)
        await fulfillment(of: [initedExpectation], timeout: 5.0)

        let track = MusicInfo(id: "wy_42", name: "Test", singer: "Singer", source: .wy, meta: MusicMeta(songId: "42"))
        let url = try await engine.requestMusicUrl(source: .wy, quality: .k320, musicInfo: track)
        let expectedHash = CryptoUtils.md5Hex("wy_42_320k")
        XCTAssertEqual(url, "https://cdn.example.com/\(expectedHash).mp3")
        engine.unload()
    }

    // MARK: - 6. LXMC Backup Codec

    func testLXMCExportAndImportRoundTrip() throws {
        let track = MusicInfo(
            id: "kw_12345",
            name: "七里香",
            singer: "周杰伦",
            source: .kw,
            interval: "04:59",
            meta: MusicMeta(songId: "12345", albumName: "七里香", qualitys: [MusicQualityItem(type: .flac, size: "32.1 MiB")])
        )
        let playlists = [
            UserPlaylist(id: BuiltInListID.default, name: "试听列表", list: [track]),
            UserPlaylist(id: BuiltInListID.love, name: "我的收藏", list: [track]),
            UserPlaylist(id: "userlist_1", name: "华语经典", list: [track]),
        ]

        let lxmcData = try LXMCBackupCodec.exportAllPlaylistsLXMC(playlists)
        let imported = try LXMCBackupCodec.importBackupData(lxmcData)
        XCTAssertEqual(imported.type, "playList_v2")
        XCTAssertEqual(imported.playlists.count, 3)
        XCTAssertEqual(imported.playlists[2].name, "华语经典")
        XCTAssertEqual(imported.playlists[2].list.first?.id, "kw_12345")
    }
}
