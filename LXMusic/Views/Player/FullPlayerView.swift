import SwiftUI

/// Immersive full-screen native player featuring blurred artwork backdrop,
/// swipeable Cover Art <-> Synchronized Karaoke Lyrics, scrubber, speed, sleep timer, and source switching.
struct FullPlayerView: View {
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settingsStore

    @State private var selectedPage: Int = 0 // 0 = Artwork, 1 = Full Lyrics
    @State private var isDraggingSlider = false
    @State private var dragProgress: Double = 0
    @State private var showSleepTimerSheet = false

    private let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                PlayerBackdropView(picUrl: player.currentPicUrl ?? player.currentTrack?.meta.picUrl)
                    .equatable()
                    .ignoresSafeArea()
            }
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showSleepTimerSheet) {
                sleepTimerSheet
            }
    }

    private func closePlayer() {
        env.showFullPlayer = false
        dismiss()
    }

    // MARK: - Content

    private var mainContent: some View {
        VStack(spacing: 14) {
            topBar
                .padding(.top, 18)

            TabView(selection: $selectedPage) {
                artworkPage.tag(0)
                LyricsView(accentColor: accentColor).tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Page indicator dots
            HStack(spacing: 7) {
                Capsule()
                    .fill(selectedPage == 0 ? Color.white : Color.white.opacity(0.3))
                    .frame(width: selectedPage == 0 ? 18 : 6, height: 5)
                Capsule()
                    .fill(selectedPage == 1 ? Color.white : Color.white.opacity(0.3))
                    .frame(width: selectedPage == 1 ? 18 : 6, height: 5)
            }
            .animation(.easeInOut(duration: 0.2), value: selectedPage)

            actionRow
            progressSection
            transportControls
        }
        .padding(.bottom, 22)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                closePlayer()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.14), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭播放器")

            VStack(spacing: 3) {
                Text(player.currentTrack?.name ?? "未在播放")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let track = player.currentTrack {
                        Text(track.singer)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)

                        let effectiveSource = player.activeSource ?? track.source
                        let sourceLabel = effectiveSource == track.source
                            ? track.source.shortName
                            : "\(track.source.shortName)→\(effectiveSource.shortName)"
                        Text(sourceLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accentColor.opacity(0.75), in: Capsule())
                            .fixedSize()

                        Text(player.activeQuality.badgeText)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.18), in: Capsule())
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Color.clear
                .frame(width: 38, height: 38)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Artwork Page

    private var artworkPage: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 10)

            CachedAsyncImage(
                urlString: player.currentPicUrl ?? player.currentTrack?.meta.picUrl,
                cornerRadius: 20,
                placeholderIcon: "music.note"
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 300, maxHeight: 300)
            .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
            .scaleEffect(player.isPlaying ? 1.0 : 0.92)
            .animation(.spring(response: 0.45, dampingFraction: 0.78), value: player.isPlaying)
            .onTapGesture {
                withAnimation { selectedPage = 1 }
            }

            // Live compact 2-line lyric preview below cover
            VStack(spacing: 6) {
                if let err = player.errorMessage, !err.isEmpty {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                } else if player.isLoading && !player.statusText.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().tint(.white).scaleEffect(0.8)
                        Text(player.statusText)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                } else if let idx = player.activeLyricLineIndex, idx < player.parsedLyric.lines.count {
                    let line = player.parsedLyric.lines[idx]
                    Text(line.text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let trans = line.extendedLyrics.first {
                        Text(trans)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                    }
                } else {
                    Text(player.currentTrack?.meta.albumName ?? "轻点封面查看歌词")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 46)
            .padding(.horizontal, 28)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation { selectedPage = 1 }
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Secondary Actions Row

    private var actionRow: some View {
        HStack {
            // Favorite
            if let track = player.currentTrack {
                let loved = library.isLoved(track)
                Button {
                    let added = library.toggleLove(track)
                    env.showToast(added ? "已添加到「我的收藏」" : "已取消收藏")
                } label: {
                    Image(systemName: loved ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(loved ? Color.red : Color.white.opacity(0.85))
                        .frame(width: 44, height: 36)
                }
            }

            Spacer()

            // Add to playlist
            Button {
                if let track = player.currentTrack {
                    closePlayer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        env.trackPendingAddToPlaylist = [track]
                    }
                }
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, height: 36)
            }

            Spacer()

            // Playback speed
            Menu {
                ForEach(speedOptions, id: \.self) { rate in
                    Button {
                        player.setPlaybackRate(rate)
                    } label: {
                        HStack {
                            Text(String(format: "%.2gx", rate))
                            if abs(settingsStore.settings.playbackRate - rate) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(String(format: "%.2gx", settingsStore.settings.playbackRate))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.14), in: Capsule())
            }

            Spacer()

            // Sleep timer
            Button {
                showSleepTimerSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "moon.zzz")
                        .font(.body)
                    if player.sleepTimerRemainingSeconds > 0 {
                        Text(FormatUtils.formatClockTime(Double(player.sleepTimerRemainingSeconds)))
                            .font(.caption2.monospacedDigit())
                    }
                }
                .foregroundStyle(player.sleepTimerRemainingSeconds > 0 ? accentColor : .white.opacity(0.85))
                .frame(minWidth: 44, minHeight: 36)
            }

            Spacer()

            // Dislike & Skip
            Button {
                player.dislikeCurrentAndSkip()
                env.showToast("已加入不喜欢并跳过")
            } label: {
                Image(systemName: "hand.thumbsdown")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, height: 36)
            }
        }
        .padding(.horizontal, 26)
    }

    // MARK: - Progress Scrubber

    private var progressSection: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { isDraggingSlider ? dragProgress : player.progress },
                    set: { newValue in
                        isDraggingSlider = true
                        dragProgress = newValue
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing {
                        isDraggingSlider = false
                        player.seek(to: dragProgress * player.duration)
                    }
                }
            )
            .tint(accentColor)

            HStack {
                Text(FormatUtils.formatClockTime(isDraggingSlider ? dragProgress * player.duration : player.currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text(FormatUtils.formatClockTime(player.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 26)
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack {
            // Play Mode
            Button {
                player.cyclePlayMode()
                env.showToast("播放模式：\(settingsStore.settings.playMode.displayName)")
            } label: {
                Image(systemName: settingsStore.settings.playMode.systemImage)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 46, height: 46)
            }

            Spacer()

            // Previous
            Button {
                player.playPrev(isAutoToggle: false)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }

            Spacer()

            // Play / Pause
            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 68, height: 68)
                        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
                    if player.isLoading {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.black)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                }
            }

            Spacer()

            // Next
            Button {
                player.playNext(isAutoToggle: false)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }

            Spacer()

            // Queue
            Button {
                closePlayer()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    env.showPlayQueue = true
                }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 46, height: 46)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Sleep Timer Sheet

    private var sleepTimerSheet: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("播完当前歌曲后再停止", isOn: Binding(
                        get: { settingsStore.settings.waitPlayEndStop },
                        set: { settingsStore.settings.waitPlayEndStop = $0 }
                    ))
                }

                Section("定时关闭") {
                    if player.sleepTimerRemainingSeconds > 0 {
                        Button(role: .destructive) {
                            player.cancelSleepTimer()
                            showSleepTimerSheet = false
                        } label: {
                            Label("取消定时（剩余 \(FormatUtils.formatClockTime(Double(player.sleepTimerRemainingSeconds)))）", systemImage: "xmark.circle")
                        }
                    }

                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { mins in
                        Button {
                            player.startSleepTimer(minutes: mins)
                            showSleepTimerSheet = false
                            env.showToast("已设置 \(mins) 分钟后停止播放")
                        } label: {
                            Text("\(mins) 分钟后停止")
                        }
                    }
                }
            }
            .navigationTitle("定时关闭")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showSleepTimerSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Isolated blurred artwork backdrop that only re-renders when `picUrl` changes,
/// avoiding redundant GPU blur work during 15fps playback time updates or sheet dismissal gestures.
private struct PlayerBackdropView: View, Equatable {
    let picUrl: String?

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.11)

            if let picUrl {
                CachedAsyncImage(urlString: picUrl, cornerRadius: 0)
                    .blur(radius: 55)
                    .scaleEffect(1.25)
                    .opacity(0.55)
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(0.5),
                    Color.black.opacity(0.68),
                    Color.black.opacity(0.88),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .drawingGroup()
        .clipped()
    }
}
