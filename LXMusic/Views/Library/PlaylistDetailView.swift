import SwiftUI
import UniformTypeIdentifiers

/// Displays tracks inside a local/custom playlist with search filtering, reordering,
/// online sync (if linked to a remote songlist), and `.lxmc` export.
struct PlaylistDetailView: View {
    let listId: String
    let accentColor: Color

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var filterText = ""
    @State private var isSyncing = false
    @State private var showClearConfirm = false
    @State private var showExporter = false
    @State private var exportDoc: LXMCExportDocument?

    private var playlist: UserPlaylist? {
        library.playlist(for: listId)
    }

    private var displayedTracks: [MusicInfo] {
        let all = playlist?.list ?? []
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(q)
                || $0.singer.lowercased().contains(q)
                || $0.meta.albumName.lowercased().contains(q)
        }
    }

    var body: some View {
        let allTracks = playlist?.list ?? []

        Group {
            if allTracks.isEmpty {
                ContentUnavailableView(
                    "歌单还是空的",
                    systemImage: "music.note",
                    description: Text("可以从搜索、排行榜或歌单广场添加喜欢的歌曲")
                )
            } else {
                List {
                    Section {
                        HStack(spacing: 12) {
                            Button {
                                player.playFromLibrary(listId: listId, index: 0)
                            } label: {
                                Label("播放全部（\(allTracks.count)）", systemImage: "play.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(accentColor)

                            if playlist?.source != nil && playlist?.sourceListId != nil {
                                Button {
                                    Task { await syncOnline() }
                                } label: {
                                    if isSyncing {
                                        ProgressView()
                                            .frame(width: 24)
                                    } else {
                                        Label("同步更新", systemImage: "arrow.clockwise")
                                            .font(.subheadline.weight(.medium))
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(accentColor)
                                .disabled(isSyncing)
                            }
                        }
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { idx, track in
                            MusicRowView(
                                track: track,
                                index: idx,
                                showSourceBadge: true,
                                accentColor: accentColor,
                                onTap: {
                                    if let realIdx = allTracks.firstIndex(where: { $0.id == track.id }) {
                                        player.playFromLibrary(listId: listId, index: realIdx)
                                    }
                                },
                                onRemove: {
                                    library.removeTracks(ids: [track.id], from: listId)
                                    env.showToast("已移除「\(track.name)」")
                                }
                            )
                        }
                        .onDelete { offsets in
                            guard filterText.isEmpty else { return }
                            library.removeTracks(at: offsets, from: listId)
                        }
                        .onMove { from, to in
                            guard filterText.isEmpty else { return }
                            library.moveTracks(in: listId, from: from, to: to)
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $filterText, prompt: "在歌单内搜索歌曲或歌手")
                .safeAreaInset(edge: .bottom) {
                    if player.currentTrack != nil {
                        Color.clear.frame(height: 76)
                    }
                }
            }
        }
        .navigationTitle(playlist?.displayName ?? "歌单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !allTracks.isEmpty && filterText.isEmpty {
                    EditButton()
                }
                Menu {
                    if let pl = playlist, !pl.list.isEmpty {
                        Button {
                            if let data = try? LXMCBackupCodec.exportSinglePlaylistLXMC(pl) {
                                exportDoc = LXMCExportDocument(data: data)
                                showExporter = true
                            }
                        } label: {
                            Label("导出此歌单 (.lxmc)", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("清空歌单", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("确认清空「\(playlist?.displayName ?? "")」内的全部歌曲？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空全部", role: .destructive) {
                library.clearTracks(in: listId)
                env.showToast("已清空歌单")
            }
            Button("取消", role: .cancel) {}
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDoc,
            contentType: .data,
            defaultFilename: "lx_list_part_\(playlist?.displayName ?? "playlist").lxmc"
        ) { result in
            if case .success = result {
                env.showToast("歌单已导出")
            }
        }
    }

    private func syncOnline() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let count = try await library.syncOnlinePlaylist(id: listId)
            env.showToast("同步完成，共 \(count) 首歌曲")
        } catch {
            env.showToast("同步失败：\(error.localizedDescription)")
        }
    }
}
