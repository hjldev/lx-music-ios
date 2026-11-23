import Foundation

/// Local disk persistence for playlists, dislike rules, custom source scripts (gzip-compressed like desktop),
/// settings, search history, music URL cache, and lyric cache.
final class PersistenceStore: @unchecked Sendable {
    static let shared = PersistenceStore()

    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    let dataDirectory: URL
    let cacheDirectory: URL
    let lyricCacheDirectory: URL

    init() {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        self.dataDirectory = appSupport.appendingPathComponent("LXMusicData", isDirectory: true)

        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        self.cacheDirectory = caches.appendingPathComponent("LXMusicCache", isDirectory: true)
        self.lyricCacheDirectory = cacheDirectory.appendingPathComponent("Lyrics", isDirectory: true)

        try? fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: lyricCacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Settings

    private var settingsURL: URL { dataDirectory.appendingPathComponent("settings.json") }

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? decoder.decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    func saveSettings(_ settings: AppSettings) {
        if let data = try? encoder.encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    // MARK: - Playlists

    private var playlistsURL: URL { dataDirectory.appendingPathComponent("playlists.json") }

    func loadPlaylists() -> [UserPlaylist]? {
        guard let data = try? Data(contentsOf: playlistsURL),
              let decoded = try? decoder.decode([UserPlaylist].self, from: data) else {
            return nil
        }
        return decoded
    }

    func savePlaylists(_ playlists: [UserPlaylist]) {
        if let data = try? encoder.encode(playlists) {
            try? data.write(to: playlistsURL, options: .atomic)
        }
    }

    // MARK: - Dislike Rules

    private var dislikeURL: URL { dataDirectory.appendingPathComponent("dislike_rules.txt") }

    func loadDislikeRules() -> String {
        (try? String(contentsOf: dislikeURL, encoding: .utf8)) ?? ""
    }

    func saveDislikeRules(_ rules: String) {
        try? rules.write(to: dislikeURL, atomically: true, encoding: .utf8)
    }

    // MARK: - UserApi Scripts (stored zlib-deflated with `gz_` prefix matching `userApi/utils.ts`)

    private struct StoredUserApi: Codable {
        var id: String
        var name: String
        var description: String
        var version: String
        var author: String
        var homepage: String
        var script: String
        var allowShowUpdateAlert: Bool
        var createdAt: Date
    }

    private var userApisURL: URL { dataDirectory.appendingPathComponent("user_apis.json") }

    func loadUserApis() -> [UserApiScript] {
        guard let data = try? Data(contentsOf: userApisURL),
              let stored = try? decoder.decode([StoredUserApi].self, from: data) else {
            return []
        }
        return stored.map { item in
            let scriptText: String
            if item.script.hasPrefix("gz_"),
               let b64 = Data(base64Encoded: String(item.script.dropFirst(3))),
               let inflated = try? CryptoUtils.zlibInflate(b64),
               let text = String(data: inflated, encoding: .utf8) {
                scriptText = text
            } else {
                scriptText = item.script
            }
            return UserApiScript(
                id: item.id,
                name: item.name,
                description: item.description,
                version: item.version,
                author: item.author,
                homepage: item.homepage,
                script: scriptText,
                allowShowUpdateAlert: item.allowShowUpdateAlert,
                createdAt: item.createdAt
            )
        }
    }

    func saveUserApis(_ scripts: [UserApiScript]) {
        let stored: [StoredUserApi] = scripts.map { item in
            let compressed: String
            if let deflated = try? CryptoUtils.zlibDeflate(Data(item.script.utf8)) {
                compressed = "gz_" + deflated.base64EncodedString()
            } else {
                compressed = item.script
            }
            return StoredUserApi(
                id: item.id,
                name: item.name,
                description: item.description,
                version: item.version,
                author: item.author,
                homepage: item.homepage,
                script: compressed,
                allowShowUpdateAlert: item.allowShowUpdateAlert,
                createdAt: item.createdAt
            )
        }
        if let data = try? encoder.encode(stored) {
            try? data.write(to: userApisURL, options: .atomic)
        }
    }

    // MARK: - Search History

    private var searchHistoryURL: URL { dataDirectory.appendingPathComponent("search_history.json") }

    func loadSearchHistory() -> [String] {
        guard let data = try? Data(contentsOf: searchHistoryURL),
              let arr = try? decoder.decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    func saveSearchHistory(_ history: [String]) {
        if let data = try? encoder.encode(Array(history.prefix(30))) {
            try? data.write(to: searchHistoryURL, options: .atomic)
        }
    }

    // MARK: - Music URL Cache (key = "\(musicId)_\(quality)")

    private struct CachedURLRecord: Codable {
        var url: String
        var savedAt: TimeInterval
    }

    private var urlCacheURL: URL { cacheDirectory.appendingPathComponent("music_urls.json") }
    private let urlCacheLock = NSLock()
    private var memoryUrlCache: [String: CachedURLRecord]?

    private func loadUrlCacheLocked() -> [String: CachedURLRecord] {
        if let mem = memoryUrlCache { return mem }
        if let data = try? Data(contentsOf: urlCacheURL),
           let decoded = try? decoder.decode([String: CachedURLRecord].self, from: data) {
            memoryUrlCache = decoded
            return decoded
        }
        memoryUrlCache = [:]
        return [:]
    }

    func getCachedMusicUrl(musicId: String, quality: AudioQuality) -> String? {
        urlCacheLock.lock()
        defer { urlCacheLock.unlock() }
        let key = "\(musicId)_\(quality.rawValue)"
        let cache = loadUrlCacheLocked()
        guard let rec = cache[key] else { return nil }
        // Expire cached streaming URLs after 20 minutes (signed CDN links often expire)
        if Date().timeIntervalSince1970 - rec.savedAt > 1200 {
            return nil
        }
        return rec.url
    }

    func saveCachedMusicUrl(musicId: String, quality: AudioQuality, url: String) {
        urlCacheLock.lock()
        defer { urlCacheLock.unlock() }
        var cache = loadUrlCacheLocked()
        let key = "\(musicId)_\(quality.rawValue)"
        cache[key] = CachedURLRecord(url: url, savedAt: Date().timeIntervalSince1970)
        // Cap cache to 500 entries
        if cache.count > 500 {
            let sortedKeys = cache.sorted { $0.value.savedAt < $1.value.savedAt }.map(\.key)
            for k in sortedKeys.prefix(cache.count - 400) {
                cache.removeValue(forKey: k)
            }
        }
        memoryUrlCache = cache
        if let data = try? encoder.encode(cache) {
            try? data.write(to: urlCacheURL, options: .atomic)
        }
    }

    func clearMusicUrlCache() {
        urlCacheLock.lock()
        defer { urlCacheLock.unlock() }
        memoryUrlCache = [:]
        try? fm.removeItem(at: urlCacheURL)
    }

    // MARK: - Lyric Cache

    private func lyricFileURL(for musicId: String) -> URL {
        lyricCacheDirectory.appendingPathComponent("\(CryptoUtils.md5Hex(musicId)).json")
    }

    func getCachedLyric(musicId: String, source: MusicSource) -> LyricInfo? {
        let url = lyricFileURL(for: musicId)
        guard let data = try? Data(contentsOf: url),
              let info = try? decoder.decode(LyricInfo.self, from: data),
              RegexHelper.test(#"\[\d{1,2}:.*\d{1,4}\]"#, in: info.lyric) else {
            return nil
        }
        // Cache validity rules matching `core/music/utils.ts:getCachedLyricInfo`
        if info.tlyric != nil {
            if info.lxlyric == nil && source != .local { return nil }
            return info
        }
        return source == .local ? info : nil
    }

    func saveCachedLyric(musicId: String, info: LyricInfo) {
        if let data = try? encoder.encode(info) {
            try? data.write(to: lyricFileURL(for: musicId), options: .atomic)
        }
    }

    // MARK: - Cache Size & Purge

    func calculateCacheSizeBytes() -> Int64 {
        var total: Int64 = 0
        let urls = [cacheDirectory]
        for root in urls {
            if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in enumerator {
                    if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        total += Int64(size)
                    }
                }
            }
        }
        total += Int64(URLCache.shared.currentDiskUsage)
        return total
    }

    func clearAllCaches() {
        clearMusicUrlCache()
        try? fm.removeItem(at: lyricCacheDirectory)
        try? fm.createDirectory(at: lyricCacheDirectory, withIntermediateDirectories: true)
        URLCache.shared.removeAllCachedResponses()
    }
}
