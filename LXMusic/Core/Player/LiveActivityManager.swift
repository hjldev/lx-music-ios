import Foundation
import UIKit
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)
public struct LXMusicActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var trackName: String
        public var singer: String
        public var currentLyric: String
        public var nextLyric: String?
        public var isPlaying: Bool
        public var currentTime: Double
        public var duration: Double

        public init(
            trackName: String,
            singer: String,
            currentLyric: String,
            nextLyric: String? = nil,
            isPlaying: Bool,
            currentTime: Double,
            duration: Double
        ) {
            self.trackName = trackName
            self.singer = singer
            self.currentLyric = currentLyric
            self.nextLyric = nextLyric
            self.isPlaying = isPlaying
            self.currentTime = currentTime
            self.duration = duration
        }
    }

    public var trackId: String

    public init(trackId: String) {
        self.trackId = trackId
    }
}
#endif

/// Coordinates Dynamic Island & Lock Screen Live Activities for real-time lyric streaming.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    #if canImport(ActivityKit)
    private var currentActivity: Activity<LXMusicActivityAttributes>?
    private var lastUpdatedLyric: String?
    #endif

    private init() {}

    var isSupported: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        #endif
        return false
    }

    func startActivity(
        track: MusicInfo,
        currentLyric: String,
        nextLyric: String?,
        isPlaying: Bool,
        currentTime: Double,
        duration: Double
    ) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), isSupported else { return }

        // End any active activities first
        stopActivity()

        let attributes = LXMusicActivityAttributes(trackId: track.id)
        let state = LXMusicActivityAttributes.ContentState(
            trackName: track.name,
            singer: track.singer,
            currentLyric: currentLyric.isEmpty ? "\(track.name) - \(track.singer)" : currentLyric,
            nextLyric: nextLyric,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration
        )

        do {
            let activity = try Activity<LXMusicActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
            self.currentActivity = activity
            self.lastUpdatedLyric = currentLyric
        } catch {
            // Silently ignore if disabled by user in Settings -> LX Music -> Live Activities
        }
        #endif
    }

    func updateActivity(
        track: MusicInfo,
        currentLyric: String,
        nextLyric: String?,
        isPlaying: Bool,
        currentTime: Double,
        duration: Double
    ) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = currentActivity else {
            if isPlaying {
                startActivity(
                    track: track,
                    currentLyric: currentLyric,
                    nextLyric: nextLyric,
                    isPlaying: isPlaying,
                    currentTime: currentTime,
                    duration: duration
                )
            }
            return
        }

        let lyricText = currentLyric.isEmpty ? "\(track.name) - \(track.singer)" : currentLyric
        // Avoid redundant updates if lyric hasn't changed unless play state toggled
        if lyricText == lastUpdatedLyric && activity.content.state.isPlaying == isPlaying {
            return
        }
        lastUpdatedLyric = lyricText

        let newState = LXMusicActivityAttributes.ContentState(
            trackName: track.name,
            singer: track.singer,
            currentLyric: lyricText,
            nextLyric: nextLyric,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration
        )

        Task {
            await activity.update(.init(state: newState, staleDate: nil))
        }
        #endif
    }

    func stopActivity() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        self.currentActivity = nil
        self.lastUpdatedLyric = nil
        #endif
    }
}
