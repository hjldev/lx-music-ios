import SwiftUI

/// Real-time synchronized lyrics view supporting:
/// - Line-by-line & true word-by-word karaoke highlight (`lxlyric`)
/// - Aligned translation (`tlyric`)
/// - Tap any line to seek immediately
/// - Smooth auto-scroll that pauses when user drags and resumes after 3 seconds
struct LyricsView: View {
    let accentColor: Color
    @Environment(PlayerController.self) private var player
    @Environment(SettingsStore.self) private var settingsStore

    @State private var isUserScrolling = false
    @State private var resumeScrollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 8) {
            if player.parsedLyric.lines.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("暂无同步歌词")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 18) {
                            Spacer().frame(height: 110)

                            ForEach(player.parsedLyric.lines) { line in
                                let isActive = (line.id == player.activeLyricLineIndex)
                                LyricLineCell(
                                    line: line,
                                    isActive: isActive,
                                    currentTimeMs: Int(player.currentTime * 1000),
                                    offsetMs: player.parsedLyric.effectiveOffsetMs,
                                    baseFontSize: settingsStore.settings.lyricFontSize,
                                    accentColor: accentColor
                                )
                                .id(line.id)
                                .onTapGesture {
                                    player.seek(to: Double(line.timeMs) / 1000.0)
                                    isUserScrolling = false
                                }
                            }

                            Spacer().frame(height: 150)
                        }
                        .padding(.horizontal, 24)
                    }
                    .simultaneousGesture(
                        DragGesture().onChanged { _ in
                            isUserScrolling = true
                            resumeScrollTask?.cancel()
                            resumeScrollTask = Task {
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                if !Task.isCancelled {
                                    isUserScrolling = false
                                }
                            }
                        }
                    )
                    .onChange(of: player.activeLyricLineIndex) { _, newIdx in
                        guard let idx = newIdx, !isUserScrolling else { return }
                        withAnimation(.easeInOut(duration: 0.32)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                    .onAppear {
                        if let idx = player.activeLyricLineIndex {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
            }

            // Quick lyric option pills (Translation / Word-by-word)
            HStack(spacing: 10) {
                if let lrc = player.currentLyricInfo {
                    if let t = lrc.tlyric, !t.isEmpty {
                        lyricTogglePill(
                            title: "译",
                            isOn: settingsStore.settings.isShowLyricTranslation
                        ) {
                            settingsStore.settings.isShowLyricTranslation.toggle()
                            player.rebuildLyricsFromSettings()
                        }
                    }
                    if let lx = lrc.lxlyric, !lx.isEmpty {
                        lyricTogglePill(
                            title: "逐字",
                            isOn: settingsStore.settings.isPlayLxlrc
                        ) {
                            settingsStore.settings.isPlayLxlrc.toggle()
                            player.rebuildLyricsFromSettings()
                        }
                    }
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func lyricTogglePill(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isOn ? accentColor.opacity(0.85) : Color.white.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
    }
}

/// Renders one lyric line, highlighting each word progressively when `lxlyric` word timings are present.
private struct LyricLineCell: View {
    let line: ParsedLyricLine
    let isActive: Bool
    let currentTimeMs: Int
    let offsetMs: Int
    let baseFontSize: Double
    let accentColor: Color

    var body: some View {
        VStack(spacing: 5) {
            if isActive && line.hasWordTiming {
                karaokeAttributedText
                    .font(.system(size: baseFontSize + 3, weight: .bold))
                    .multilineTextAlignment(.center)
                    .shadow(color: accentColor.opacity(0.45), radius: 6, y: 0)
            } else {
                Text(line.text)
                    .font(.system(size: isActive ? baseFontSize + 3 : baseFontSize, weight: isActive ? .bold : .regular))
                    .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.48))
                    .multilineTextAlignment(.center)
                    .shadow(color: isActive ? accentColor.opacity(0.35) : .clear, radius: 5)
            }

            ForEach(Array(line.extendedLyrics.enumerated()), id: \.offset) { _, ext in
                Text(ext)
                    .font(.system(size: max(12, baseFontSize - 4), weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Color.white.opacity(0.85) : Color.white.opacity(0.36))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .scaleEffect(isActive ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isActive)
        .contentShape(Rectangle())
    }

    private var karaokeAttributedText: Text {
        var combined = AttributedString()
        for word in line.words {
            let progress = LyricParser.wordProgress(line: line, word: word, atMs: currentTimeMs, offsetMs: offsetMs)
            var seg = AttributedString(word.text)
            if progress >= 0.85 {
                seg.foregroundColor = Color.white
            } else if progress > 0.05 {
                seg.foregroundColor = accentColor.opacity(0.95)
            } else {
                seg.foregroundColor = Color.white.opacity(0.48)
            }
            combined.append(seg)
        }
        return Text(combined)
    }
}
