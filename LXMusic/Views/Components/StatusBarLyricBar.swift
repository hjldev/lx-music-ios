import SwiftUI

/// Floating translucent capsule positioned just beneath the native iOS Status Bar,
/// streaming real-time rolling lyrics while the user navigates across lists, search, or settings.
struct StatusBarLyricBar: View {
    let accentColor: Color
    @Environment(PlayerController.self) private var player
    @Environment(AppEnvironment.self) private var env

    @State private var wavePhase: CGFloat = 0.0

    var body: some View {
        if player.currentTrack != nil {
            Button {
                env.showFullPlayer = true
            } label: {
                HStack(spacing: 8) {
                    // Mini music equalizer waves
                    HStack(spacing: 2) {
                        ForEach(0..<3) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(accentColor)
                                .frame(width: 2.2, height: waveHeight(for: i))
                        }
                    }
                    .frame(width: 14, height: 14)

                    // Current lyric text or fallback to track info
                    Text(displayText)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(displayText)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)),
                            removal: .opacity
                        ))

                    // Minimal track progress indicator
                    if player.duration > 0 {
                        Text("\(Int(player.progress * 100))%")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.28), value: displayText)
            .onAppear {
                startWaveAnimation()
            }
        }
    }

    private var displayText: String {
        let preview = player.currentLyricPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            return preview
        }
        if let track = player.currentTrack {
            return "\(track.name) - \(track.singer)"
        }
        return ""
    }

    private func waveHeight(for index: Int) -> CGFloat {
        guard player.isPlaying else { return 5 }
        let heights: [[CGFloat]] = [
            [4, 12, 7],
            [10, 5, 13],
            [6, 14, 8],
            [12, 6, 11]
        ]
        let step = Int(wavePhase) % heights.count
        return heights[step][index]
    }

    private func startWaveAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { timer in
            if player.isPlaying {
                wavePhase += 1
            }
        }
    }
}
