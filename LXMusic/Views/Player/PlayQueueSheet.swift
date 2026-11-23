import SwiftUI

/// Displays the upcoming "稍后播放" (`tempPlayList`) queue and the current backing playlist.
struct PlayQueueSheet: View {
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerController.self) private var player
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        NavigationStack {
            List {
                if !player.tempPlayList.isEmpty {
                    Section {
                        ForEach(Array(player.tempPlayList.enumerated()), id: \.element.id) { idx, item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.musicInfo.name)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(item.musicInfo.singer)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    player.removeFromTempPlayList(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        HStack {
                            Text("稍后播放（\(player.tempPlayList.count)）")
                            Spacer()
                            Button("清空") {
                                player.clearTempPlayList()
                            }
                            .font(.caption)
                        }
                    }
                }

                let backing = player.currentBackingTracks
                Section("当前播放列表（\(backing.count)）") {
                    if backing.isEmpty {
                        Text("播放列表为空")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(backing.enumerated()), id: \.element.id) { idx, track in
                            let isCurrent = player.currentTrack?.id == track.id
                            Button {
                                if let listId = player.playerListId {
                                    player.playList(tracks: backing, startIndex: idx, listId: listId)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    if isCurrent {
                                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                                            .font(.caption.bold())
                                            .foregroundStyle(accentColor)
                                            .frame(width: 22)
                                    } else {
                                        Text("\(idx + 1)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.name)
                                            .font(.body.weight(isCurrent ? .semibold : .regular))
                                            .foregroundStyle(isCurrent ? accentColor : .primary)
                                            .lineLimit(1)
                                        Text("\(track.source.shortName) · \(track.singer)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("播放队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        player.cyclePlayMode()
                    } label: {
                        Label(settingsStore.settings.playMode.displayName, systemImage: settingsStore.settings.playMode.systemImage)
                            .font(.caption)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
