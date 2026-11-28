import Foundation
import Observation

/// Item in the playback queue (`tempPlayList` / `playedList`) mirroring `LX.Player.PlayMusicInfo`.
struct QueueItem: Identifiable, Hashable, Sendable {
    let uid: UUID
    let listId: String
    let musicInfo: MusicInfo
    let isTempPlay: Bool

    var id: UUID { uid }

    init(listId: String, musicInfo: MusicInfo, isTempPlay: Bool) {
        self.uid = UUID()
        self.listId = listId
        self.musicInfo = musicInfo
        self.isTempPlay = isTempPlay
    }
}

/// Complete playback coordinator faithfully porting LX Music Desktop's playback state machine
/// (`src/renderer/core/player/action.ts`, `utils.ts`, `timeoutStop.ts`, `core/music/online.ts`).
@Observable
@MainActor
final class PlayerController {

    // MARK: - Published Player State

    private(set) var currentTrack: MusicInfo?
    private(set) var currentListId: String?
    private(set) var playerListId: String?
    private(set) var playerPlayIndex: Int = -1
    private(set) var isTempPlay: Bool = false

    private(set) var tempPlayList: [QueueItem] = []
    private(set) var playedList: [QueueItem] = []

    static let maxConsecutiveFailures = 3

    private(set) var isPlaying: Bool = false
    private(set) var isLoading: Bool = false
    private(set) var statusText: String = ""
    private(set) var errorMessage: String?
    private(set) var activeQuality: AudioQuality = .k128
    private(set) var activeSource: MusicSource?
    private(set) var consecutiveFailureCount: Int = 0

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private(set) var currentPicUrl: String?
    private(set) var currentLyricInfo: LyricInfo?
    private(set) var parsedLyric: ParsedLyricDocument = .empty
    private(set) var activeLyricLineIndex: Int?

    var currentLyricPreview: String {
        if let idx = activeLyricLineIndex, idx < parsedLyric.lines.count {
            return parsedLyric.lines[idx].text
        }
        return currentTrack?.singer ?? ""
    }

    // Sleep timer state (`timeoutStop.ts`)
    private(set) var sleepTimerRemainingSeconds: Int = -1
    private var isPlayedStop: Bool = false
    private var sleepTimerTask: Task<Void, Never>?

    // Internal control state
    private let audioEngine = AudioPlayerEngine()
    private let crossSourceMatcher: CrossSourceMatcher
    private let autoSkipDelayNanoseconds: UInt64
    private unowned let settingsStore: SettingsStore
    private unowned let libraryStore: LibraryStore
    private unowned let dislikeStore: DislikeStore
    private unowned let userApiStore: UserApiStore

    private var playSessionToken = UUID()
    private var playTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var preloadedTrackId: String?
    private var cachedRandomNext: QueueItem?
    private var retryCountForCurrentTrack = 0
    private var failedSourcesForCurrentTrack: Set<MusicSource> = []
    private var hasLoadedAudioItem = false
    private var lastNowPlayingSyncTime: TimeInterval = 0

    // MARK: - Init

    init(
        settingsStore: SettingsStore,
        libraryStore: LibraryStore,
        dislikeStore: DislikeStore,
        userApiStore: UserApiStore,
        crossSourceMatcher: CrossSourceMatcher = .shared,
        autoSkipDelayNanoseconds: UInt64 = 3_500_000_000
    ) {
        self.settingsStore = settingsStore
        self.libraryStore = libraryStore
        self.dislikeStore = dislikeStore
        self.userApiStore = userApiStore
        self.crossSourceMatcher = crossSourceMatcher
        self.autoSkipDelayNanoseconds = autoSkipDelayNanoseconds

        wireAudioEngineCallbacks()
    }

    private func wireAudioEngineCallbacks() {
        audioEngine.onTimeUpdate = { [weak self] cur, dur in
            self?.handleTimeUpdate(currentTime: cur, duration: dur)
        }
        audioEngine.onReadyToPlay = { [weak self] in
            guard let self else { return }
            self.isLoading = false
            self.statusText = ""
            self.errorMessage = nil
            self.retryCountForCurrentTrack = 0
            self.consecutiveFailureCount = 0
        }
        audioEngine.onEnded = { [weak self] in
            self?.handlePlaybackEnded()
        }
        audioEngine.onError = { [weak self] err in
            self?.handleAudioPlaybackError(err)
        }
        audioEngine.onRemotePlay = { [weak self] in self?.resume() }
        audioEngine.onRemotePause = { [weak self] in self?.pause() }
        audioEngine.onRemoteTogglePlayPause = { [weak self] in self?.togglePlayPause() }
        audioEngine.onRemoteNext = { [weak self] in self?.playNext(isAutoToggle: false) }
        audioEngine.onRemotePrev = { [weak self] in self?.playPrev(isAutoToggle: false) }
        audioEngine.onRemoteSeek = { [weak self] seconds in self?.seek(to: seconds) }
    }

    // MARK: - Public Playback Actions

    /// Plays a specific list starting at `startIndex` (clears `tempPlayList`, matching `playList`).
    func playList(tracks: [MusicInfo], startIndex: Int, listId: String) {
        guard !tracks.isEmpty, startIndex >= 0, startIndex < tracks.count else { return }
        consecutiveFailureCount = 0
        if listId == BuiltInListID.temp {
            libraryStore.setTempList(tracks: tracks)
        }
        if settingsStore.settings.isAutoCleanPlayedList || playerListId != listId {
            playedList.removeAll()
        }
        tempPlayList.removeAll()
        cachedRandomNext = nil
        playerListId = listId
        playerPlayIndex = startIndex

        startPlaying(QueueItem(listId: listId, musicInfo: tracks[startIndex], isTempPlay: false))
    }

    /// Plays a single track from an existing library list by index.
    func playFromLibrary(listId: String, index: Int) {
        let tracks = libraryStore.tracks(in: listId)
        playList(tracks: tracks, startIndex: index, listId: listId)
    }

    /// Plays an ad-hoc track (e.g., from Search, Leaderboard, or SongList Detail) using `temp` list.
    func playAdHoc(tracks: [MusicInfo], startIndex: Int, sourceListId: String? = nil) {
        libraryStore.setTempList(tracks: tracks, sourceListId: sourceListId)
        playList(tracks: tracks, startIndex: startIndex, listId: BuiltInListID.temp)
    }

    func togglePlayPause() {
        isPlayedStop = false
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        isPlayedStop = false
        consecutiveFailureCount = 0
        guard let track = currentTrack else { return }
        if (!hasLoadedAudioItem || duration == 0) && !isLoading {
            // Re-trigger resolution if previous load failed or playback was stopped
            startPlaying(QueueItem(listId: currentListId ?? BuiltInListID.temp, musicInfo: track, isTempPlay: isTempPlay))
            return
        }
        audioEngine.play()
        isPlaying = true
        syncNowPlayingInfo(force: true)
    }

    func pause() {
        audioEngine.pause()
        isPlaying = false
        syncNowPlayingInfo(force: true)
    }

    func stop() {
        playTask?.cancel()
        preloadTask?.cancel()
        audioEngine.stop()
        LiveActivityManager.shared.stopActivity()
        currentTrack = nil
        currentListId = nil
        activeSource = nil
        hasLoadedAudioItem = false
        consecutiveFailureCount = 0
        failedSourcesForCurrentTrack.removeAll()
        isPlaying = false
        isLoading = false
        statusText = ""
        errorMessage = nil
        currentTime = 0
        duration = 0
        currentPicUrl = nil
        currentLyricInfo = nil
        parsedLyric = .empty
        activeLyricLineIndex = nil
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(duration, 0))
        currentTime = clamped
        audioEngine.seek(to: clamped)
        updateActiveLyricLine()
        syncNowPlayingInfo(force: true)
    }

    func setPlaybackRate(_ rate: Double) {
        settingsStore.settings.playbackRate = rate
        audioEngine.setPlaybackRate(rate, isPlaying: isPlaying)
        syncNowPlayingInfo(force: true)
    }

    func cyclePlayMode() {
        settingsStore.settings.playMode = settingsStore.settings.playMode.next
        playedList.removeAll()
        cachedRandomNext = nil
        if settingsStore.settings.playMode == .random, let track = currentTrack, !isTempPlay, let listId = currentListId {
            addToPlayedList(QueueItem(listId: listId, musicInfo: track, isTempPlay: false))
        }
    }

    func rebuildLyricsFromSettings() {
        parsedLyric = LyricParser.parse(
            info: currentLyricInfo,
            showTranslation: settingsStore.settings.isShowLyricTranslation,
            playWordByWord: settingsStore.settings.isPlayLxlrc
        )
        updateActiveLyricLine()
    }

    // MARK: - Queue Management (`tempPlayList` / Play Next)

    func addToPlayNext(_ track: MusicInfo, fromListId listId: String = BuiltInListID.temp, toTop: Bool = false) {
        let item = QueueItem(listId: listId, musicInfo: track, isTempPlay: true)
        if toTop {
            tempPlayList.insert(item, at: 0)
        } else {
            tempPlayList.append(item)
        }
        if currentTrack == nil {
            playNext(isAutoToggle: false)
        }
    }

    func removeFromTempPlayList(at index: Int) {
        guard index >= 0 && index < tempPlayList.count else { return }
        tempPlayList.remove(at: index)
    }

    func clearTempPlayList() {
        tempPlayList.removeAll()
    }

    var currentBackingTracks: [MusicInfo] {
        guard let listId = playerListId else { return [] }
        return libraryStore.tracks(in: listId)
    }

    // MARK: - Dislike

    func dislikeCurrentAndSkip() {
        guard let track = currentTrack else { return }
        dislikeStore.addDislike(musicInfo: track)
        playNext(isAutoToggle: true)
    }

    // MARK: - Next / Prev State Machine (`core/player/action.ts` & `utils.ts`)

    func playNext(isAutoToggle: Bool = false) {
        isPlayedStop = false
        if !isAutoToggle {
            consecutiveFailureCount = 0
        }

        // 1. Always consume `tempPlayList` ("Play Next") first
        if !tempPlayList.isEmpty {
            let nextItem = tempPlayList.removeFirst()
            startPlaying(nextItem)
            return
        }

        guard let currentTrack, let backingListId = playerListId else {
            stop()
            return
        }

        let currentList = libraryStore.tracks(in: backingListId)

        // 2. Forward navigation through random `playedList` history
        if !playedList.isEmpty {
            let anchorId = isTempPlay
                ? (playerPlayIndex >= 0 && playerPlayIndex < currentList.count ? currentList[playerPlayIndex].id : nil)
                : currentTrack.id
            if let anchorId, var idx = playedList.firstIndex(where: { $0.musicInfo.id == anchorId }) {
                idx += 1
                while idx < playedList.count {
                    let candidate = playedList[idx]
                    if candidate.listId == backingListId && !currentList.contains(where: { $0.id == candidate.musicInfo.id }) {
                        playedList.remove(at: idx)
                        continue
                    }
                    startPlaying(candidate)
                    return
                }
            }
        }

        // 3. Preloaded random next track
        if let cached = cachedRandomNext {
            cachedRandomNext = nil
            startPlaying(cached)
            return
        }

        // 4. Filter playable tracks (excluding disliked & already-played random tracks)
        let anchorTrack = (playerPlayIndex >= 0 && playerPlayIndex < currentList.count) ? currentList[playerPlayIndex] : nil
        let filtered = filterPlayableList(
            listId: backingListId,
            list: currentList,
            anchorMusic: anchorTrack,
            isNext: true
        )
        guard !filtered.list.isEmpty else {
            stop()
            return
        }

        var idx = filtered.anchorIndex
        if idx == -1 { idx = 0 }

        var mode = settingsStore.settings.playMode
        // Manual Next coerces list/singleLoop/none -> listLoop
        if !isAutoToggle && (mode == .list || mode == .singleLoop || mode == .none) {
            mode = .listLoop
        }

        let nextIndex: Int
        switch mode {
        case .listLoop:
            nextIndex = (idx >= filtered.list.count - 1) ? 0 : (idx + 1)
        case .random:
            nextIndex = Int.random(in: 0..<filtered.list.count)
        case .list:
            if idx >= filtered.list.count - 1 { return }
            nextIndex = idx + 1
        case .singleLoop:
            nextIndex = idx
        case .none:
            return
        }

        let nextMusic = filtered.list[nextIndex]
        if let realIdx = currentList.firstIndex(where: { $0.id == nextMusic.id }) {
            playerPlayIndex = realIdx
        }
        startPlaying(QueueItem(listId: backingListId, musicInfo: nextMusic, isTempPlay: false))
    }

    func playPrev(isAutoToggle: Bool = false) {
        isPlayedStop = false
        if !isAutoToggle {
            consecutiveFailureCount = 0
        }
        guard let currentTrack, let backingListId = playerListId else {
            stop()
            return
        }

        let currentList = libraryStore.tracks(in: backingListId)

        // 1. Backward navigation through `playedList`
        if !playedList.isEmpty {
            let anchorId = isTempPlay
                ? (playerPlayIndex >= 0 && playerPlayIndex < currentList.count ? currentList[playerPlayIndex].id : nil)
                : currentTrack.id
            if let anchorId, var idx = playedList.firstIndex(where: { $0.musicInfo.id == anchorId }) {
                idx -= 1
                while idx >= 0 {
                    let candidate = playedList[idx]
                    if candidate.listId == backingListId && !currentList.contains(where: { $0.id == candidate.musicInfo.id }) {
                        playedList.remove(at: idx)
                        idx -= 1
                        continue
                    }
                    startPlaying(candidate)
                    return
                }
            }
        }

        // 2. Filter playable tracks
        let anchorTrack = (playerPlayIndex >= 0 && playerPlayIndex < currentList.count) ? currentList[playerPlayIndex] : nil
        let filtered = filterPlayableList(
            listId: backingListId,
            list: currentList,
            anchorMusic: anchorTrack,
            isNext: false
        )
        guard !filtered.list.isEmpty else {
            stop()
            return
        }

        var idx = filtered.anchorIndex
        if idx == -1 { idx = 0 }

        var nextIndex = idx
        // When on a temp track, Prev returns to the anchored backing list track
        if !isTempPlay {
            var mode = settingsStore.settings.playMode
            if !isAutoToggle && (mode == .list || mode == .singleLoop || mode == .none) {
                mode = .listLoop
            }
            switch mode {
            case .random:
                nextIndex = Int.random(in: 0..<filtered.list.count)
            case .listLoop, .list:
                nextIndex = (idx <= 0) ? (filtered.list.count - 1) : (idx - 1)
            case .singleLoop:
                nextIndex = idx
            case .none:
                return
            }
        }

        let prevMusic = filtered.list[nextIndex]
        if let realIdx = currentList.firstIndex(where: { $0.id == prevMusic.id }) {
            playerPlayIndex = realIdx
        }
        startPlaying(QueueItem(listId: backingListId, musicInfo: prevMusic, isTempPlay: false))
    }

    private func filterPlayableList(
        listId: String,
        list: [MusicInfo],
        anchorMusic: MusicInfo?,
        isNext: Bool
    ) -> (list: [MusicInfo], anchorIndex: Int) {
        var canPlayList: [MusicInfo] = []
        var filteredList: [MusicInfo] = []
        var anchorWasDisliked = false
        var playedIds = Set(playedList.filter { $0.listId == listId && !$0.isTempPlay }.map(\.musicInfo.id))

        for item in list {
            if dislikeStore.hasDislike(item) {
                if item.id != anchorMusic?.id {
                    continue
                }
                anchorWasDisliked = true
            }
            canPlayList.append(item)
            if playedIds.remove(item.id) != nil {
                continue
            }
            filteredList.append(item)
        }

        var workingList: [MusicInfo]
        if filteredList.isEmpty && !playedList.isEmpty {
            playedList.removeAll()
            workingList = canPlayList
        } else {
            workingList = filteredList.isEmpty ? canPlayList : filteredList
        }

        guard let anchor = anchorMusic else {
            return (workingList, -1)
        }

        if !anchorWasDisliked {
            let idx = workingList.firstIndex(where: { $0.id == anchor.id }) ?? -1
            return (workingList, idx)
        }

        // Exact dislike-removal index adjustment from `worker/main/list.ts`
        guard let curIdx = workingList.firstIndex(where: { $0.id == anchor.id }) else {
            return (workingList, -1)
        }
        workingList.remove(at: curIdx)
        guard !workingList.isEmpty else { return ([], -1) }

        let adjustedIndex: Int
        if isNext {
            adjustedIndex = (curIdx - 1 < 0) ? (workingList.count - 1) : (curIdx - 1)
        } else {
            adjustedIndex = min(curIdx, workingList.count - 1)
        }
        return (workingList, adjustedIndex)
    }

    private func addToPlayedList(_ item: QueueItem) {
        guard !playedList.contains(where: { $0.musicInfo.id == item.musicInfo.id }) else { return }
        playedList.append(item)
    }

    // MARK: - Sleep Timer (`core/player/timeoutStop.ts`)

    func startSleepTimer(minutes: Int) {
        guard minutes > 0 else {
            cancelSleepTimer()
            return
        }
        cancelSleepTimer()
        isPlayedStop = false
        let totalSec = min(minutes, 1440) * 60
        sleepTimerRemainingSeconds = totalSec

        sleepTimerTask = Task { [weak self] in
            var remaining = totalSec
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
                self?.sleepTimerRemainingSeconds = remaining
            }
            self?.handleSleepTimerExpired()
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerRemainingSeconds = -1
        isPlayedStop = false
    }

    private func handleSleepTimerExpired() {
        sleepTimerTask = nil
        sleepTimerRemainingSeconds = -1
        isPlayedStop = true
        if !settingsStore.settings.waitPlayEndStop && isPlaying {
            pause()
        }
    }

    // MARK: - Core Track Loading & Online Resolution (`core/music/online.ts` & `utils.ts`)

    private func startPlaying(_ item: QueueItem, isRefresh: Bool = false, isAudioRetry: Bool = false) {
        playTask?.cancel()
        preloadTask?.cancel()
        preloadedTrackId = nil
        cachedRandomNext = nil
        hasLoadedAudioItem = false

        if !isAudioRetry {
            retryCountForCurrentTrack = 0
            failedSourcesForCurrentTrack.removeAll()
        }

        let token = UUID()
        playSessionToken = token

        currentTrack = item.musicInfo
        currentListId = item.listId
        activeSource = item.musicInfo.source
        isTempPlay = item.isTempPlay
        if !item.isTempPlay {
            playerListId = item.listId
            let backing = libraryStore.tracks(in: item.listId)
            if let idx = backing.firstIndex(where: { $0.id == item.musicInfo.id }) {
                playerPlayIndex = idx
            }
            if settingsStore.settings.playMode == .random {
                addToPlayedList(item)
            }
        }

        isLoading = true
        isPlaying = false
        errorMessage = nil
        statusText = isAudioRetry ? "播放出错，正在切换其他音源..." : "正在获取播放链接..."
        currentTime = 0
        duration = Double(FormatUtils.parseIntervalSeconds(item.musicInfo.interval))
        if !isAudioRetry {
            currentPicUrl = item.musicInfo.meta.picUrl
            currentLyricInfo = nil
            parsedLyric = .empty
            activeLyricLineIndex = nil
        }

        audioEngine.pause()
        syncNowPlayingInfo(force: true)

        let track = item.musicInfo
        let excludedSources = failedSourcesForCurrentTrack
        playTask = Task { [weak self] in
            guard let self else { return }

            // Fetch cover art & lyrics in parallel without blocking audio playback
            async let picTask: Void = self.loadCoverArt(for: track, sessionToken: token, skip: isAudioRetry)
            async let lyricTask: Void = self.loadLyrics(for: track, sessionToken: token, skip: isAudioRetry)

            do {
                let resolved = try await self.resolvePlayURL(
                    for: track,
                    isRefresh: isRefresh,
                    excludedSources: excludedSources,
                    allowToggleSource: true,
                    sessionToken: token
                )
                guard self.playSessionToken == token, !Task.isCancelled else { return }

                self.activeQuality = resolved.quality
                self.activeSource = resolved.actualSource
                self.statusText = "正在缓冲音频..."

                guard let url = URL(string: resolved.url) else {
                    throw MusicSDKError.apiError("无效的音频链接")
                }

                self.hasLoadedAudioItem = true
                self.audioEngine.load(url: url, playbackRate: self.settingsStore.settings.playbackRate, autoPlay: true)
                self.isPlaying = true
                self.syncNowPlayingInfo(force: true)
            } catch {
                guard self.playSessionToken == token, !Task.isCancelled else { return }
                self.handleURLResolutionFailure(error, for: track, sessionToken: token)
            }

            _ = await (picTask, lyricTask)
        }
    }

    struct ResolvedPlayURL: Sendable {
        let url: String
        let quality: AudioQuality
        let actualSource: MusicSource
        let matchedTrack: MusicInfo
    }

    /// Resolves a playable audio URL for `track`, automatically falling back across `kg`, `tx`, `wy`, `mg` (and `kw`)
    /// via `CrossSourceMatcher` when the primary source fails — mirroring `core/music/utils.ts:handleGetOnlineMusicUrl`.
    func resolvePlayURL(
        for track: MusicInfo,
        isRefresh: Bool,
        excludedSources: Set<MusicSource> = [],
        allowToggleSource: Bool = true,
        sessionToken: UUID? = nil
    ) async throws -> ResolvedPlayURL {
        guard userApiStore.activeScript != nil else {
            throw MusicSDKError.noActiveCustomSource
        }
        guard userApiStore.runtimeStatus.isInitialized else {
            throw MusicSDKError.apiError(userApiStore.runtimeStatus.message ?? "自定义音源尚未就绪")
        }

        let primarySupported = userApiStore.supportedQualities(for: track.source)
        let targetQuality = AudioQuality.resolvePlayQuality(
            preferred: settingsStore.settings.playQuality,
            musicInfo: track,
            supportedBySource: primarySupported
        )

        var primaryError: Error?

        // 1. Try primary source first (unless excluded after an AVPlayer failure)
        if !excludedSources.contains(track.source) {
            if !isRefresh, let cached = PersistenceStore.shared.getCachedMusicUrl(musicId: track.id, quality: targetQuality) {
                return ResolvedPlayURL(url: cached, quality: targetQuality, actualSource: track.source, matchedTrack: track)
            }

            if userApiStore.supportsSource(track.source) {
                do {
                    let url = try await userApiStore.requestMusicUrl(source: track.source, quality: targetQuality, musicInfo: track)
                    PersistenceStore.shared.saveCachedMusicUrl(musicId: track.id, quality: targetQuality, url: url)
                    return ResolvedPlayURL(url: url, quality: targetQuality, actualSource: track.source, matchedTrack: track)
                } catch {
                    if Task.isCancelled { throw error }
                    if case MusicSDKError.noActiveCustomSource = error { throw error }
                    primaryError = error
                }
            } else {
                primaryError = MusicSDKError.customSourceNotSupported(track.source)
            }
        }

        // 2. Cross-source fallback across other online platforms (`kg`, `tx`, `wy`, `mg`, `kw`)
        guard allowToggleSource, track.source != .local else {
            throw primaryError ?? MusicSDKError.apiError("获取播放链接失败")
        }

        var triedSources = excludedSources
        triedSources.insert(track.source)

        let eligibleSources = MusicSource.onlineSources.filter {
            !triedSources.contains($0) && userApiStore.supportsSource($0)
        }
        guard !eligibleSources.isEmpty else {
            throw primaryError ?? MusicSDKError.apiError("所有音源平台均获取播放链接失败")
        }

        if let sessionToken, self.playSessionToken == sessionToken {
            self.statusText = "当前源失败，正在尝试换源..."
        }

        let candidates = await crossSourceMatcher.findMusic(
            for: track,
            in: eligibleSources,
            ignoreCache: isRefresh
        )
        if Task.isCancelled { throw CancellationError() }

        var lastError: Error = primaryError ?? MusicSDKError.apiError("其他平台未找到匹配歌曲")

        for candidate in candidates {
            if Task.isCancelled { throw CancellationError() }
            guard !triedSources.contains(candidate.source) else { continue }
            triedSources.insert(candidate.source)
            guard userApiStore.supportsSource(candidate.source) else { continue }

            let supported = userApiStore.supportedQualities(for: candidate.source)
            var altQuality = AudioQuality.resolvePlayQuality(
                preferred: settingsStore.settings.playQuality,
                musicInfo: candidate,
                supportedBySource: supported
            )
            if !candidate.meta._qualitys.isEmpty && !candidate.hasQuality(altQuality) {
                if let bestAvailable = candidate.meta.qualitys
                    .map(\.type)
                    .filter({ supported.contains($0) })
                    .max(by: { $0.sortRank < $1.sortRank }) {
                    altQuality = bestAvailable
                }
            }

            if let sessionToken, self.playSessionToken == sessionToken {
                self.statusText = "正在尝试 \(candidate.source.shortName) 音源..."
            }

            if !isRefresh, let cached = PersistenceStore.shared.getCachedMusicUrl(musicId: candidate.id, quality: altQuality) {
                PersistenceStore.shared.saveCachedMusicUrl(musicId: track.id, quality: targetQuality, url: cached)
                return ResolvedPlayURL(url: cached, quality: altQuality, actualSource: candidate.source, matchedTrack: candidate)
            }

            do {
                let url = try await userApiStore.requestMusicUrl(source: candidate.source, quality: altQuality, musicInfo: candidate)
                PersistenceStore.shared.saveCachedMusicUrl(musicId: candidate.id, quality: altQuality, url: url)
                PersistenceStore.shared.saveCachedMusicUrl(musicId: track.id, quality: targetQuality, url: url)
                return ResolvedPlayURL(url: url, quality: altQuality, actualSource: candidate.source, matchedTrack: candidate)
            } catch {
                if Task.isCancelled { throw error }
                if case MusicSDKError.noActiveCustomSource = error { throw error }
                lastError = error
            }
        }

        if candidates.isEmpty {
            throw MusicSDKError.apiError("所有平台均获取失败（未匹配到其他平台歌曲）")
        }
        throw MusicSDKError.apiError("所有平台均获取播放链接失败（\(lastError.localizedDescription)）")
    }

    // MARK: - Cover & Lyrics Loading (with Cache)

    private func loadCoverArt(for track: MusicInfo, sessionToken: UUID, skip: Bool = false) async {
        if skip { return }
        if let pic = track.meta.picUrl, !pic.isEmpty {
            if playSessionToken == sessionToken {
                currentPicUrl = pic
                syncNowPlayingInfo(force: true)
            }
            return
        }
        guard let sdk = MusicSDKRegistry.shared.sdk(for: track.source) else { return }
        if let fetched = try? await sdk.getPic(musicInfo: track), !fetched.isEmpty {
            guard playSessionToken == sessionToken else { return }
            currentPicUrl = fetched
            libraryStore.updateTrackPic(musicId: track.id, picUrl: fetched)
            syncNowPlayingInfo(force: true)
        }
    }

    private func loadLyrics(for track: MusicInfo, sessionToken: UUID, skip: Bool = false) async {
        if skip { return }
        if let cached = PersistenceStore.shared.getCachedLyric(musicId: track.id, source: track.source) {
            guard playSessionToken == sessionToken else { return }
            applyLyricInfo(cached)
            return
        }

        if let sdk = MusicSDKRegistry.shared.sdk(for: track.source),
           let info = try? await sdk.getLyric(musicInfo: track),
           RegexHelper.test(#"\[\d{1,2}:.*\d{1,4}\]"#, in: info.lyric) {
            PersistenceStore.shared.saveCachedLyric(musicId: track.id, info: info)
            guard playSessionToken == sessionToken else { return }
            applyLyricInfo(info)
        }
    }

    private func applyLyricInfo(_ info: LyricInfo) {
        currentLyricInfo = info
        rebuildLyricsFromSettings()
    }

    // MARK: - Time, Preload, End & Error Handling

    private func handleTimeUpdate(currentTime: Double, duration: Double) {
        self.currentTime = currentTime
        if duration > 0 {
            self.duration = duration
        }
        updateActiveLyricLine()
        syncNowPlayingInfo(force: false)

        // Preload next track URL in last 10 seconds (`usePreloadNextMusic.ts`)
        if duration > 10 && (duration - currentTime) < 10 && preloadedTrackId != currentTrack?.id {
            preloadedTrackId = currentTrack?.id
            preloadUpcomingTrack()
        }
    }

    private func updateActiveLyricLine() {
        let ms = Int(currentTime * 1000)
        let idx = LyricParser.activeLineIndex(in: parsedLyric, atMs: ms)
        if idx != activeLyricLineIndex {
            activeLyricLineIndex = idx
            if settingsStore.settings.enableLockScreenLyric {
                syncNowPlayingInfo(force: true)
            }
        }
    }

    private func preloadUpcomingTrack() {
        guard let nextItem = peekNextPlayItem() else { return }
        if settingsStore.settings.playMode == .random && tempPlayList.isEmpty {
            cachedRandomNext = nextItem
        }
        preloadTask?.cancel()
        preloadTask = Task { [weak self] in
            guard let self else { return }
            _ = try? await self.resolvePlayURL(for: nextItem.musicInfo, isRefresh: false, allowToggleSource: true)
        }
    }

    private func peekNextPlayItem() -> QueueItem? {
        if let firstTemp = tempPlayList.first { return firstTemp }
        guard let backingListId = playerListId else { return nil }
        let list = libraryStore.tracks(in: backingListId)
        let anchor = (playerPlayIndex >= 0 && playerPlayIndex < list.count) ? list[playerPlayIndex] : nil
        let filtered = filterPlayableList(listId: backingListId, list: list, anchorMusic: anchor, isNext: true)
        guard !filtered.list.isEmpty else { return nil }
        let idx = max(0, filtered.anchorIndex)

        switch settingsStore.settings.playMode {
        case .listLoop:
            return QueueItem(listId: backingListId, musicInfo: filtered.list[(idx + 1) % filtered.list.count], isTempPlay: false)
        case .random:
            return QueueItem(listId: backingListId, musicInfo: filtered.list[Int.random(in: 0..<filtered.list.count)], isTempPlay: false)
        case .list:
            guard idx + 1 < filtered.list.count else { return nil }
            return QueueItem(listId: backingListId, musicInfo: filtered.list[idx + 1], isTempPlay: false)
        case .singleLoop:
            return QueueItem(listId: backingListId, musicInfo: filtered.list[idx], isTempPlay: false)
        case .none:
            return nil
        }
    }

    private func handlePlaybackEnded() {
        isPlaying = false
        consecutiveFailureCount = 0
        if isPlayedStop {
            isPlayedStop = false
            syncNowPlayingInfo(force: true)
            return
        }
        if settingsStore.settings.playMode == .singleLoop {
            seek(to: 0)
            audioEngine.play()
            isPlaying = true
            syncNowPlayingInfo(force: true)
            return
        }
        if settingsStore.settings.playMode == .none {
            syncNowPlayingInfo(force: true)
            return
        }
        playNext(isAutoToggle: true)
    }

    private func handleURLResolutionFailure(_ error: Error, for track: MusicInfo, sessionToken: UUID) {
        handleTrackPlaybackFailure(error, sessionToken: sessionToken)
    }

    private func handleAudioPlaybackError(_ error: Error) {
        guard let track = currentTrack, !isPlayedStop else { return }
        hasLoadedAudioItem = false

        let failedSrc = activeSource ?? track.source
        failedSourcesForCurrentTrack.insert(failedSrc)

        let remainingSources = MusicSource.onlineSources.filter {
            !failedSourcesForCurrentTrack.contains($0) && userApiStore.supportsSource($0)
        }

        if !remainingSources.isEmpty && retryCountForCurrentTrack < MusicSource.onlineSources.count {
            retryCountForCurrentTrack += 1
            startPlaying(
                QueueItem(listId: currentListId ?? BuiltInListID.temp, musicInfo: track, isTempPlay: isTempPlay),
                isRefresh: true,
                isAudioRetry: true
            )
            return
        }

        handleTrackPlaybackFailure(error, sessionToken: playSessionToken)
    }

    private func handleTrackPlaybackFailure(_ error: Error, sessionToken: UUID) {
        isLoading = false
        isPlaying = false
        statusText = ""

        // Never auto-skip or count consecutive failures when no custom source script is configured
        if case MusicSDKError.noActiveCustomSource = error {
            errorMessage = error.localizedDescription
            syncNowPlayingInfo(force: true)
            return
        }

        consecutiveFailureCount += 1

        if consecutiveFailureCount >= Self.maxConsecutiveFailures {
            stopDueToConsecutiveFailures()
            return
        }

        errorMessage = error.localizedDescription
        syncNowPlayingInfo(force: true)

        guard settingsStore.settings.autoSkipOnError, !isPlayedStop else { return }

        // Delay then skip to next track
        let delayNs = autoSkipDelayNanoseconds
        playTask = Task { [weak self] in
            if delayNs > 0 {
                try? await Task.sleep(nanoseconds: delayNs)
            }
            guard let self, self.playSessionToken == sessionToken, !Task.isCancelled else { return }
            self.playNext(isAutoToggle: true)
        }
    }

    private func stopDueToConsecutiveFailures() {
        playTask?.cancel()
        playTask = nil
        preloadTask?.cancel()
        preloadTask = nil
        audioEngine.stop()
        LiveActivityManager.shared.stopActivity()
        hasLoadedAudioItem = false
        isLoading = false
        isPlaying = false
        statusText = ""
        errorMessage = "连续 \(Self.maxConsecutiveFailures) 首歌曲播放失败，已停止播放"
    }

    private func syncNowPlayingInfo(force: Bool) {
        guard let track = currentTrack else { return }
        let now = Date().timeIntervalSince1970
        if !force && (now - lastNowPlayingSyncTime) < 1.0 { return }
        lastNowPlayingSyncTime = now

        let lines = parsedLyric.lines
        let idx = activeLyricLineIndex ?? -1
        let curLyric = (idx >= 0 && idx < lines.count) ? lines[idx].text : nil
        let prevLyric = (idx > 0 && idx - 1 < lines.count) ? lines[idx - 1].text : nil
        let nextLyric = (idx >= 0 && idx + 1 < lines.count) ? lines[idx + 1].text : nil

        let settings = settingsStore.settings
        audioEngine.updateNowPlaying(
            track: track,
            picUrl: currentPicUrl,
            currentLyric: curLyric,
            prevLyric: prevLyric,
            nextLyric: nextLyric,
            lyricLineIndex: idx,
            currentTime: currentTime,
            duration: duration,
            isPlaying: isPlaying,
            rate: settings.playbackRate,
            enableLockScreenLyric: settings.enableLockScreenLyric,
            mode: settings.lockScreenLyricMode,
            lines: settings.lockScreenLyricLines
        )

        // Stream lyrics to Dynamic Island & Lock Screen Live Activity
        LiveActivityManager.shared.updateActivity(
            track: track,
            currentLyric: curLyric ?? "",
            nextLyric: nextLyric,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration
        )
    }

    /// Explicitly refreshes lock screen metadata and live activity (e.g. after settings change).
    func refreshNowPlayingMetadata() {
        syncNowPlayingInfo(force: true)
    }
}
