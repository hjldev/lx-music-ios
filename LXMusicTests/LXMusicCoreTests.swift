import XCTest
@testable import LXMusic

final class LXMusicCoreTests: XCTestCase {

    // MARK: - 1. Crypto & Compression

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

    // MARK: - 3. Quality Downgrade Order

    func testQualityDowngradeOrder() {
        let track = MusicInfo(
            id: "kw_1",
            name: "Song",
            singer: "Artist",
            source: .kw,
            meta: MusicMeta(
                songId: "1",
                qualitys: [
                    MusicQualityItem(type: .k128, size: "3.5M"),
                    MusicQualityItem(type: .k320, size: "8.9M"),
                ]
            )
        )
        let chosen = AudioQuality.resolvePlayQuality(
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

        let exact = MusicInfo(id: "1", name: "badsong", singer: "artist", source: .kw, meta: MusicMeta(songId: "1"))
        let bySong = MusicInfo(id: "2", name: "OnlySong", singer: "Anyone", source: .kw, meta: MusicMeta(songId: "2"))
        let bySinger = MusicInfo(id: "3", name: "Random", singer: "BlockedSinger", source: .kw, meta: MusicMeta(songId: "3"))
        let withAtSign = MusicInfo(id: "4", name: "A@B", singer: "Singer", source: .kw, meta: MusicMeta(songId: "4"))
        let ok = MusicInfo(id: "5", name: "GoodSong", singer: "GoodSinger", source: .kw, meta: MusicMeta(songId: "5"))

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
            kw: { type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] }
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

        let track = MusicInfo(id: "kw_42", name: "Test", singer: "Singer", source: .kw, meta: MusicMeta(songId: "42"))
        let url = try await engine.requestMusicUrl(source: .kw, quality: .k320, musicInfo: track)
        let expectedHash = CryptoUtils.md5Hex("kw_42_320k")
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

    // MARK: - 7. Cross-Source Crypto, Matching & Multi-Platform Metadata

    func testCrossSourceCryptoSignatures() throws {
        // TX zzcSign: must handle index 40 safely without crashing and strip / + = \
        let sign = CrossSourceMatcher.zzcSign(#"{"hello":"world"}"#)
        XCTAssertTrue(sign.hasPrefix("zzc"))
        XCTAssertEqual(sign, sign.lowercased())
        XCTAssertFalse(sign.contains("/"))
        XCTAssertFalse(sign.contains("+"))
        XCTAssertFalse(sign.contains("="))
        XCTAssertFalse(sign.contains("\\"))

        // WY eapi: must encrypt with AES-128-ECB key `e82ckenh8dichen8` and decrypt back to expected plaintext
        let url = "/api/search/song/list/page"
        let jsonText = #"{"keyword":"七里香","limit":25}"#
        let hexParams = try CrossSourceMatcher.wyEapiParams(url: url, jsonText: jsonText)
        let cipherData = try XCTUnwrap(Data(hexString: hexParams))
        let plainData = try CryptoUtils.aesDecrypt(data: cipherData, key: Data("e82ckenh8dichen8".utf8), isECB: true)
        let plainStr = try XCTUnwrap(String(data: plainData, encoding: .utf8))
        let expectedDigest = CryptoUtils.md5Hex("nobody\(url)use\(jsonText)md5forencrypt")
        XCTAssertEqual(plainStr, "\(url)-36cd479b6b5-\(jsonText)-36cd479b6b5-\(expectedDigest)")

        // MG signature
        let mgSig = CrossSourceMatcher.mgSignature(time: "1700000000000", query: "周杰伦")
        XCTAssertEqual(mgSig.deviceId, "963B7AA0D21511ED807EE5846EC87D20")
        XCTAssertEqual(mgSig.sign.count, 32)
    }

    func testCrossSourceMatchAndRank() {
        let target = MusicInfo(
            id: "kw_100",
            name: "七里香",
            singer: "周杰伦",
            source: .kw,
            interval: "04:59",
            meta: MusicMeta(songId: "100", albumName: "七里香")
        )

        let kgLive = MusicInfo(
            id: "kg_live",
            name: "七里香 (Live)",
            singer: "周杰伦",
            source: .kg,
            interval: "04:59",
            meta: MusicMeta(songId: "1", albumName: "演唱会", hash: "HASH_LIVE")
        )
        let kgWrongDuration = MusicInfo(
            id: "kg_short",
            name: "七里香",
            singer: "周杰伦",
            source: .kg,
            interval: "03:00",
            meta: MusicMeta(songId: "2", albumName: "七里香", hash: "HASH_SHORT")
        )
        let kgStudio = MusicInfo(
            id: "kg_ok",
            name: "七里香",
            singer: "周杰伦",
            source: .kg,
            interval: "05:01",
            meta: MusicMeta(songId: "3", albumName: "七里香", hash: "HASH_OK")
        )
        let txExact = MusicInfo(
            id: "tx_exact",
            name: "七里香",
            singer: "周杰伦",
            source: .tx,
            interval: "04:59",
            meta: MusicMeta(songId: "001TXMID", albumName: "七里香", strMediaMid: "001MEDIA")
        )
        let wyMatch = MusicInfo(
            id: "wy_match",
            name: "七里香",
            singer: "周杰伦",
            source: .wy,
            interval: "04:58",
            meta: MusicMeta(songId: "186016", albumName: "精选集")
        )

        let ranked = CrossSourceMatcher.matchAndRank(
            target: target,
            sourceLists: [[kgLive, kgWrongDuration, kgStudio], [txExact], [wyMatch]]
        )

        XCTAssertEqual(ranked.map(\.id), ["tx_exact", "kg_ok", "wy_match"])
    }

    func testLegacyDictionaryIncludesMultiPlatformMetadata() {
        let kgTrack = MusicInfo(
            id: "123_ABCD",
            name: "TestKG",
            singer: "Artist",
            source: .kg,
            meta: MusicMeta(
                songId: "123",
                qualitys: [MusicQualityItem(type: .k128, size: "3M", hash: "ABCD")],
                hash: "ABCD",
                albumAudioId: "999"
            )
        )
        let kgLegacy = kgTrack.toLegacyDictionary()
        XCTAssertEqual(kgLegacy["source"] as? String, "kg")
        XCTAssertEqual(kgLegacy["hash"] as? String, "ABCD")
        XCTAssertEqual(kgLegacy["albumAudioId"] as? String, "999")

        let txTrack = MusicInfo(
            id: "tx_001MID",
            name: "TestTX",
            singer: "Artist",
            source: .tx,
            meta: MusicMeta(songId: "001MID", strMediaMid: "001MEDIA", txSongId: "777", albumMid: "001ALB")
        )
        let txLegacy = txTrack.toLegacyDictionary()
        XCTAssertEqual(txLegacy["songmid"] as? String, "001MID")
        XCTAssertEqual(txLegacy["strMediaMid"] as? String, "001MEDIA")
        XCTAssertEqual(txLegacy["songId"] as? String, "777")
        XCTAssertEqual(txLegacy["albumMid"] as? String, "001ALB")

        let mgTrack = MusicInfo(
            id: "mg_555",
            name: "TestMG",
            singer: "Artist",
            source: .mg,
            meta: MusicMeta(songId: "555", copyrightId: "60054701934")
        )
        let mgLegacy = mgTrack.toLegacyDictionary()
        XCTAssertEqual(mgLegacy["copyrightId"] as? String, "60054701934")
    }

    // MARK: - 8. Cross-Source Playback Fallback & Consecutive Failure Stop

    @MainActor
    func testPlayerControllerCrossSourceFallbackWhenKWFails() async throws {
        PersistenceStore.shared.clearMusicUrlCache()
        let settingsStore = SettingsStore()
        let libraryStore = LibraryStore()
        let dislikeStore = DislikeStore()
        let userApiStore = UserApiStore(settingsStore: settingsStore)

        let scriptCode = """
        /**
         * @name Fallback Test Source
         * @version 1.0.0
         */
        const { EVENT_NAMES, on, send } = globalThis.lx;
        on(EVENT_NAMES.request, ({ source, action, info }) => {
          if (source === 'wy') {
            return Promise.resolve('https://cdn.example.com/wy_' + info.musicInfo.songmid + '.mp3');
          }
          return Promise.reject(new Error(source + ' unavailable'));
        });
        send(EVENT_NAMES.inited, {
          status: true,
          sources: {
            kw: { type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] },
            kg: { type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] },
            tx: { type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] },
            wy: { type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] },
            mg: { type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] }
          }
        });
        """

        let imported = try userApiStore.importScript(rawCode: scriptCode, autoActivate: true)
        defer { userApiStore.delete(scriptId: imported.id) }

        for _ in 0..<50 {
            if userApiStore.runtimeStatus.isInitialized { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(userApiStore.runtimeStatus.isInitialized)

        let mockMatcher = CrossSourceMatcher { source, _, _ in
            switch source {
            case .kg:
                return [MusicInfo(id: "kg_1", name: "稻香", singer: "周杰伦", source: .kg, interval: "03:43", meta: MusicMeta(songId: "kg1", qualitys: [MusicQualityItem(type: .k320)], hash: "H1"))]
            case .wy:
                return [MusicInfo(id: "wy_2", name: "稻香", singer: "周杰伦", source: .wy, interval: "03:43", meta: MusicMeta(songId: "wy2", qualitys: [MusicQualityItem(type: .k320)]))]
            case .mg:
                return [MusicInfo(id: "mg_3", name: "稻香", singer: "周杰伦", source: .mg, interval: "03:43", meta: MusicMeta(songId: "mg3", qualitys: [MusicQualityItem(type: .k320)], copyrightId: "C3"))]
            case .tx:
                return [MusicInfo(id: "tx_4", name: "稻香", singer: "周杰伦", source: .tx, interval: "03:43", meta: MusicMeta(songId: "tx4", qualitys: [MusicQualityItem(type: .k320)], strMediaMid: "M4"))]
            default:
                return []
            }
        }

        let player = PlayerController(
            settingsStore: settingsStore,
            libraryStore: libraryStore,
            dislikeStore: dislikeStore,
            userApiStore: userApiStore,
            crossSourceMatcher: mockMatcher,
            autoSkipDelayNanoseconds: 20_000_000
        )

        let kwTrack = MusicInfo(
            id: "kw_999",
            name: "稻香",
            singer: "周杰伦",
            source: .kw,
            interval: "03:43",
            meta: MusicMeta(songId: "999", qualitys: [MusicQualityItem(type: .k320)])
        )

        let resolved = try await player.resolvePlayURL(for: kwTrack, isRefresh: true)
        XCTAssertEqual(resolved.actualSource, .wy)
        XCTAssertEqual(resolved.url, "https://cdn.example.com/wy_wy2.mp3")
    }

    @MainActor
    func testPlayerControllerStopsAfterThreeConsecutiveFailures() async throws {
        PersistenceStore.shared.clearMusicUrlCache()
        let settingsStore = SettingsStore()
        settingsStore.settings.autoSkipOnError = true
        settingsStore.settings.playMode = .listLoop
        let libraryStore = LibraryStore()
        let dislikeStore = DislikeStore()
        let userApiStore = UserApiStore(settingsStore: settingsStore)

        let scriptCode = """
        /**
         * @name Always Fail Source
         * @version 1.0.0
         */
        const { EVENT_NAMES, on, send } = globalThis.lx;
        on(EVENT_NAMES.request, ({ source }) => {
          return Promise.reject(new Error(source + ' failed'));
        });
        send(EVENT_NAMES.inited, {
          status: true,
          sources: {
            kw: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] },
            kg: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] },
            tx: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] },
            wy: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] },
            mg: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] }
          }
        });
        """

        let imported = try userApiStore.importScript(rawCode: scriptCode, autoActivate: true)
        defer { userApiStore.delete(scriptId: imported.id) }

        for _ in 0..<50 {
            if userApiStore.runtimeStatus.isInitialized { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(userApiStore.runtimeStatus.isInitialized)

        let mockMatcher = CrossSourceMatcher { source, query, _ in
            let title = query.split(separator: " ").first.map(String.init) ?? query
            return [MusicInfo(
                id: "\(source.rawValue)_\(title)",
                name: title,
                singer: "Singer",
                source: source,
                interval: "03:00",
                meta: MusicMeta(songId: "alt_\(source.rawValue)", qualitys: [MusicQualityItem(type: .k128)])
            )]
        }

        let player = PlayerController(
            settingsStore: settingsStore,
            libraryStore: libraryStore,
            dislikeStore: dislikeStore,
            userApiStore: userApiStore,
            crossSourceMatcher: mockMatcher,
            autoSkipDelayNanoseconds: 50_000_000
        )

        let tracks = (1...5).map { idx in
            MusicInfo(
                id: "kw_fail_\(idx)",
                name: "FailSong\(idx)",
                singer: "Singer",
                source: .kw,
                interval: "03:00",
                meta: MusicMeta(songId: "\(idx)", qualitys: [MusicQualityItem(type: .k128)])
            )
        }

        player.playList(tracks: tracks, startIndex: 0, listId: BuiltInListID.temp)

        for _ in 0..<100 {
            if player.consecutiveFailureCount >= PlayerController.maxConsecutiveFailures { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // Wait an extra 200ms to confirm playback stays stopped and does NOT skip to track #4
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(player.consecutiveFailureCount, 3)
        XCTAssertEqual(player.currentTrack?.id, "kw_fail_3")
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertEqual(player.errorMessage, "连续 3 首歌曲播放失败，已停止播放")
    }
}
