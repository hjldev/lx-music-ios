import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Low-level iOS native audio engine wrapping `AVPlayer`, `AVAudioSession` (background audio),
/// `MPNowPlayingInfoCenter` (Lock Screen / Control Center metadata + artwork), and `MPRemoteCommandCenter`.
@MainActor
final class AudioPlayerEngine: NSObject {
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    private var currentPlaybackRate: Float = 1.0
    private var artworkCache: [String: UIImage] = [:]
    private var artworkTask: Task<Void, Never>?

    // Callbacks wired by PlayerController
    var onTimeUpdate: ((Double, Double) -> Void)?
    var onReadyToPlay: (() -> Void)?
    var onEnded: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onRemotePlay: (() -> Void)?
    var onRemotePause: (() -> Void)?
    var onRemoteTogglePlayPause: (() -> Void)?
    var onRemoteNext: (() -> Void)?
    var onRemotePrev: (() -> Void)?
    var onRemoteSeek: ((Double) -> Void)?

    override init() {
        super.init()
        configureAudioSession()
        configureRemoteCommands()
        observeAudioSessionNotifications()
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
    }

    // MARK: - Audio Session & Remote Commands

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // Ignored on simulator or if interrupted; retried on play()
        }
    }

    private func observeAudioSessionNotifications() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case .began:
                    self.onRemotePause?()
                case .ended:
                    if let optVal = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                       AVAudioSession.InterruptionOptions(rawValue: optVal).contains(.shouldResume) {
                        self.onRemotePlay?()
                    }
                @unknown default:
                    break
                }
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let reasonVal = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal),
                  reason == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in
                self?.onRemotePause?()
            }
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onRemotePlay?() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onRemotePause?() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onRemoteTogglePlayPause?() }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onRemoteNext?() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onRemotePrev?() }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = posEvent.positionTime
            Task { @MainActor in self?.onRemoteSeek?(target) }
            return .success
        }
    }

    // MARK: - Playback Controls

    func load(url: URL, playbackRate: Double, autoPlay: Bool) {
        cleanupCurrentItem()
        configureAudioSession()

        let headers = ["User-Agent": HTTPClient.defaultUserAgent]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        currentPlaybackRate = Float(playbackRate)

        if let existing = player {
            existing.replaceCurrentItem(with: item)
        } else {
            let p = AVPlayer(playerItem: item)
            p.automaticallyWaitsToMinimizeStalling = true
            self.player = p
            installTimeObserver(on: p)
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.onReadyToPlay?()
                case .failed:
                    let err = observedItem.error ?? NSError(domain: "LXAudio", code: -1, userInfo: [NSLocalizedDescriptionKey: "音频加载失败"])
                    self.onError?(err)
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onEnded?()
            }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let err = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
                ?? NSError(domain: "LXAudio", code: -2, userInfo: [NSLocalizedDescriptionKey: "音频播放中断"])
            Task { @MainActor [weak self] in
                self?.onError?(err)
            }
        }

        if autoPlay {
            play()
        }
    }

    func play() {
        configureAudioSession()
        player?.playImmediately(atRate: currentPlaybackRate)
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        cleanupCurrentItem()
        player?.replaceCurrentItem(with: nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func setPlaybackRate(_ rate: Double, isPlaying: Bool) {
        currentPlaybackRate = Float(rate)
        if isPlaying {
            player?.rate = currentPlaybackRate
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func installTimeObserver(on player: AVPlayer) {
        let interval = CMTime(seconds: 0.066, preferredTimescale: 600) // ~15fps for smooth karaoke lyrics
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] cmTime in
            Task { @MainActor [weak self] in
                guard let self, let item = self.player?.currentItem else { return }
                let cur = cmTime.seconds.isFinite ? max(0, cmTime.seconds) : 0
                let durRaw = item.duration.seconds
                let dur = (durRaw.isFinite && durRaw > 0) ? durRaw : 0
                self.onTimeUpdate?(cur, dur)
            }
        }
    }

    private func cleanupCurrentItem() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
            self.failObserver = nil
        }
    }

    // MARK: - Lock Screen / Control Center Now Playing Metadata

    func updateNowPlaying(
        track: MusicInfo,
        picUrl: String?,
        currentLyric: String?,
        prevLyric: String?,
        nextLyric: String?,
        lyricLineIndex: Int,
        currentTime: Double,
        duration: Double,
        isPlaying: Bool,
        rate: Double,
        enableLockScreenLyric: Bool,
        mode: LockScreenLyricMode,
        lines: Int
    ) {
        let hasLyric = (currentLyric != nil && !currentLyric!.isEmpty)

        // Title & Artist handling for lock screen
        let title: String
        let artist: String
        if enableLockScreenLyric && mode != .artworkOnly && hasLyric {
            title = currentLyric!
            artist = "\(track.name) · \(track.singer)"
        } else {
            title = track.name
            artist = track.singer
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: track.meta.albumName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0.0,
        ]

        // Artwork handling: dynamic lyric poster or regular cover art
        let baseImage = picUrl.flatMap { artworkCache[$0] }
        if enableLockScreenLyric && mode != .titleOnly && hasLyric {
            let lyricArtwork = LockScreenLyricArtworkRenderer.shared.render(
                trackId: track.id,
                lineIndex: lyricLineIndex,
                baseArtwork: baseImage,
                trackName: track.name,
                artistName: track.singer,
                currentLyric: currentLyric!,
                prevLyric: prevLyric,
                nextLyric: nextLyric,
                displayLines: lines
            )
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: lyricArtwork.size) { _ in lyricArtwork }
        } else if let baseImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: baseImage.size) { _ in baseImage }
        } else if let picUrl, !picUrl.isEmpty, let url = URL(string: picUrl) {
            loadArtworkForNowPlaying(url: url, cacheKey: picUrl)
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtworkForNowPlaying(url: URL, cacheKey: String) {
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.artworkCache.count > 20 { self.artworkCache.removeAll() }
                self.artworkCache[cacheKey] = image
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}
