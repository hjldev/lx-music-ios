import SwiftUI

/// Online SongList Detail page showing playlist hero metadata, Play All / Collect actions, and paginated songs.
struct SongListDetailView: View {
    let item: OnlineSongListItem
    let accentColor: Color

    @Environment(AppEnvironment.self) private var env
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library

    @State private var info: OnlineSongListInfo?
    @State private var tracks: [MusicInfo] = []
    @State private var page: Int = 1
    @State private var total: Int = 0
    @State private var hasMore: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && tracks.isEmpty {
                ProgressView("加载歌单曲目中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, tracks.isEmpty {
                ContentUnavailableView {
                    Label("加载歌单失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") {
                        Task { await loadDetail(reset: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                }
            } else {
                List {
                    Section {
                        headerCard
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .listRowSeparator(.hidden)
                    }

                    Section {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                            MusicRowView(
                                track: track,
                                index: idx,
                                showSourceBadge: false,
                                accentColor: accentColor
                            ) {
                                player.playAdHoc(tracks: tracks, startIndex: idx, sourceListId: item.id)
                            }
                            .onAppear {
                                if idx == tracks.count - 1 && hasMore && !isLoading {
                                    Task { await loadDetail(reset: false) }
                                }
                            }
                        }

                        if isLoading && !tracks.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        }
                    } header: {
                        HStack {
                            Text("歌曲列表（\(total > 0 ? total : tracks.count)）")
                            Spacer()
                            Text(item.source.displayName)
                                .font(.caption2)
                                .foregroundStyle(accentColor)
                        }
                    }
                }
                .listStyle(.plain)
                .safeAreaInset(edge: .bottom) {
                    if player.currentTrack != nil {
                        Color.clear.frame(height: 76)
                    }
                }
            }
        }
        .navigationTitle(info?.name.isEmpty == false ? info!.name : item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if tracks.isEmpty {
                await loadDetail(reset: true)
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CachedAsyncImage(
                    urlString: info?.img ?? item.img,
                    cornerRadius: 12,
                    placeholderIcon: "music.note.list"
                )
                .frame(width: 108, height: 108)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

                VStack(alignment: .leading, spacing: 6) {
                    Text(info?.name.isEmpty == false ? info!.name : item.name)
                        .font(.headline)
                        .lineLimit(2)

                    if let author = info?.author ?? (item.author.isEmpty ? nil : item.author), !author.isEmpty {
                        Label(author, systemImage: "person.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let count = info?.playCount ?? item.playCount, !count.isEmpty, count != "0" {
                        Label("播放 \(count)", systemImage: "headphones")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let desc = info?.desc ?? item.desc, !desc.isEmpty {
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    guard !tracks.isEmpty else { return }
                    player.playAdHoc(tracks: tracks, startIndex: 0, sourceListId: item.id)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .disabled(tracks.isEmpty)

                Button {
                    guard !tracks.isEmpty else { return }
                    let name = info?.name.isEmpty == false ? info!.name : item.name
                    let created = library.createUserPlaylist(
                        name: name,
                        tracks: tracks,
                        source: item.source,
                        sourceListId: item.id
                    )
                    env.showToast("已收藏为歌单「\(created.displayName)」")
                } label: {
                    Label("收藏歌单", systemImage: "folder.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(accentColor)
                .disabled(tracks.isEmpty)
            }
        }
    }

    private func loadDetail(reset: Bool) async {
        guard let sdk = MusicSDKRegistry.shared.sdk(for: item.source) else { return }
        if reset {
            page = 1
            errorMessage = nil
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let res = try await sdk.getSongListDetail(idOrUrl: item.id, page: page)
            if reset {
                info = res.info
                tracks = res.list
            } else {
                let existing = Set(tracks.map(\.id))
                tracks.append(contentsOf: res.list.filter { !existing.contains($0.id) })
            }
            total = res.total
            hasMore = !res.list.isEmpty && tracks.count < res.total && res.limit > 0
            page += 1
        } catch {
            if reset {
                errorMessage = error.localizedDescription
            }
        }
    }
}
