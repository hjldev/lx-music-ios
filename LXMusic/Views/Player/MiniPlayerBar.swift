import SwiftUI

/// Floating translucent glass mini-player bar docked above the tab bar whenever a track is active.
struct MiniPlayerBar: View {
    let accentColor: Color
    @Environment(AppEnvironment.self) private var env
    @Environment(PlayerController.self) private var player

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: 12) {
                CachedAsyncImage(urlString: player.currentPicUrl ?? track.meta.picUrl, cornerRadius: 8)
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let err = player.errorMessage, !err.isEmpty {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else if player.isLoading && !player.statusText.isEmpty {
                        Text(player.statusText)
                            .font(.caption2)
                            .foregroundStyle(accentColor)
                            .lineLimit(1)
                    } else {
                        Text(player.currentLyricPreview.isEmpty ? track.singer : player.currentLyricPreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(accentColor.opacity(0.22), lineWidth: 2.5)
                            Circle()
                                .trim(from: 0, to: player.progress)
                                .stroke(accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))

                            if player.isLoading {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(accentColor)
                                    .offset(x: player.isPlaying ? 0 : 1)
                            }
                        }
                        .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.playNext(isAutoToggle: false)
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 34)
                    }
                    .buttonStyle(.plain)

                    Button {
                        env.showPlayQueue = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 34)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                env.showFullPlayer = true
            }
        }
    }
}
