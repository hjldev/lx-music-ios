import SwiftUI
import UIKit

/// Standard iOS song row used across Search, Leaderboard, SongList Detail, and My Playlists.
struct MusicRowView: View {
    let track: MusicInfo
    var index: Int? = nil
    var showSourceBadge: Bool = false
    var showCover: Bool = false
    let accentColor: Color
    let onTap: () -> Void
    var onRemove: (() -> Void)? = nil

    @Environment(AppEnvironment.self) private var env
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DislikeStore.self) private var dislikeStore

    private var isCurrentTrack: Bool {
        player.currentTrack?.id == track.id
    }

    private var isDisliked: Bool {
        dislikeStore.hasDislike(track)
    }

    var body: some View {
        HStack(spacing: 12) {
            leadingView

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if isCurrentTrack {
                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(accentColor)
                    }
                    Text(track.name)
                        .font(.body.weight(isCurrentTrack ? .semibold : .regular))
                        .foregroundStyle(isCurrentTrack ? accentColor : (isDisliked ? .secondary : .primary))
                        .strikethrough(isDisliked, color: .secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    if showSourceBadge {
                        Text(track.source.shortName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                    }

                    if let highest = track.highestQuality, highest != .k128 {
                        Text(highest.badgeText)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(highest == .flac24bit ? .orange : (highest == .flac ? .green : .blue))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke((highest == .flac24bit ? Color.orange : (highest == .flac ? Color.green : Color.blue)).opacity(0.6), lineWidth: 0.8)
                            )
                    }

                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let interval = track.interval, !interval.isEmpty, interval != "--/--" {
                Text(interval)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Menu {
                menuContent
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            menuContent
        }
    }

    @ViewBuilder
    private var leadingView: some View {
        if showCover {
            CachedAsyncImage(urlString: track.meta.picUrl, cornerRadius: 6)
                .frame(width: 44, height: 44)
        } else if let index {
            Text("\(index + 1)")
                .font(.subheadline.monospacedDigit().weight(index < 3 ? .bold : .regular))
                .foregroundStyle(index < 3 ? accentColor : .secondary)
                .frame(width: 28, alignment: .center)
        }
    }

    private var subtitleText: String {
        if track.meta.albumName.isEmpty {
            return track.singer
        }
        return "\(track.singer) · \(track.meta.albumName)"
    }

    @ViewBuilder
    private var menuContent: some View {
        Button {
            onTap()
        } label: {
            Label("立即播放", systemImage: "play.fill")
        }

        Button {
            player.addToPlayNext(track, toTop: true)
            env.showToast("已加入下一首播放")
        } label: {
            Label("下一首播放", systemImage: "text.insert")
        }

        Button {
            let loved = library.toggleLove(track)
            env.showToast(loved ? "已添加到「我的收藏」" : "已从「我的收藏」移除")
        } label: {
            let loved = library.isLoved(track)
            Label(loved ? "取消收藏" : "收藏歌曲", systemImage: loved ? "heart.slash" : "heart")
        }

        Button {
            env.trackPendingAddToPlaylist = [track]
        } label: {
            Label("添加到歌单...", systemImage: "text.badge.plus")
        }

        Button {
            env.trackPendingSourceSwitch = track
        } label: {
            Label("换源查找同名歌曲", systemImage: "arrow.triangle.2.circlepath")
        }

        Button {
            UIPasteboard.general.string = "\(track.name) - \(track.singer)"
            env.showToast("已复制歌曲信息")
        } label: {
            Label("复制歌名与歌手", systemImage: "doc.on.doc")
        }

        Divider()

        if let onRemove {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("从列表移除", systemImage: "trash")
            }
        }

        Button(role: .destructive) {
            dislikeStore.addDislike(musicInfo: track)
            env.showToast("已加入不喜欢列表")
            if isCurrentTrack {
                player.playNext(isAutoToggle: true)
            }
        } label: {
            Label("不喜欢这首歌", systemImage: "hand.thumbsdown")
        }
    }
}
