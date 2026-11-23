import SwiftUI

/// Multi-source Music Leaderboard (`排行榜`) covering all 10–51 charts across KW/KG/TX/WY/MG.
struct LeaderboardView: View {
    let accentColor: Color
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(PlayerController.self) private var player

    @State private var selectedSource: MusicSource = .kw
    @State private var selectedBoard: LeaderboardBoard?
    @State private var tracks: [MusicInfo] = []
    @State private var page: Int = 1
    @State private var total: Int = 0
    @State private var hasMore: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var showAllBoardsSheet = false

    private var boards: [LeaderboardBoard] {
        MusicSDKRegistry.shared.sdk(for: selectedSource)?.leaderboardBoards ?? []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SourcePickerBar(selected: $selectedSource, accentColor: accentColor)

                // Quick Horizontal Board Strip + "全部榜单" Button
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(boards.prefix(12)) { board in
                                let isSelected = (board.id == selectedBoard?.id)
                                Button {
                                    selectedBoard = board
                                    Task { await loadTracks(reset: true) }
                                } label: {
                                    Text(board.name)
                                        .font(.caption.weight(isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? accentColor : .primary)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(isSelected ? accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 16)
                    }

                    Button {
                        showAllBoardsSheet = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.title3)
                            .foregroundStyle(accentColor)
                            .padding(.trailing, 14)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)

                Divider()

                tracksContent
            }
            .navigationTitle(selectedBoard?.name ?? "排行榜")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard !tracks.isEmpty else { return }
                        player.playAdHoc(tracks: tracks, startIndex: 0, sourceListId: selectedBoard?.id)
                    } label: {
                        Label("全部播放", systemImage: "play.fill")
                    }
                    .disabled(tracks.isEmpty)
                }
            }
            .sheet(isPresented: $showAllBoardsSheet) {
                allBoardsSheet
            }
            .onChange(of: selectedSource) { _, newSource in
                settingsStore.settings.defaultLeaderboardSource = newSource
                selectedBoard = MusicSDKRegistry.shared.sdk(for: newSource)?.leaderboardBoards.first
                Task { await loadTracks(reset: true) }
            }
            .task {
                if selectedBoard == nil {
                    selectedSource = settingsStore.settings.defaultLeaderboardSource
                    selectedBoard = MusicSDKRegistry.shared.sdk(for: selectedSource)?.leaderboardBoards.first
                    await loadTracks(reset: true)
                }
            }
        }
    }

    @ViewBuilder
    private var tracksContent: some View {
        if isLoading && tracks.isEmpty {
            ProgressView("加载榜单中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, tracks.isEmpty {
            ContentUnavailableView {
                Label("加载失败", systemImage: "chart.bar.xaxis")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("重试") {
                    Task { await loadTracks(reset: true) }
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
            }
        } else {
            List {
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        MusicRowView(
                            track: track,
                            index: idx,
                            showSourceBadge: false,
                            accentColor: accentColor
                        ) {
                            player.playAdHoc(tracks: tracks, startIndex: idx, sourceListId: selectedBoard?.id)
                        }
                        .onAppear {
                            if idx == tracks.count - 1 && hasMore && !isLoading {
                                Task { await loadTracks(reset: false) }
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
                        Text("\(selectedBoard?.name ?? "排行榜") · 共 \(total > 0 ? total : tracks.count) 首")
                        Spacer()
                        if !tracks.isEmpty {
                            Button("批量收藏") {
                                env.trackPendingAddToPlaylist = tracks
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable {
                await loadTracks(reset: true)
            }
            .safeAreaInset(edge: .bottom) {
                if player.currentTrack != nil {
                    Color.clear.frame(height: 76)
                }
            }
        }
    }

    private var allBoardsSheet: some View {
        NavigationStack {
            List(boards) { board in
                Button {
                    selectedBoard = board
                    showAllBoardsSheet = false
                    Task { await loadTracks(reset: true) }
                } label: {
                    HStack {
                        Text(board.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if board.id == selectedBoard?.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(accentColor)
                        }
                    }
                }
            }
            .navigationTitle("\(selectedSource.displayName)全部榜单（\(boards.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showAllBoardsSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadTracks(reset: Bool) async {
        guard let board = selectedBoard,
              let sdk = MusicSDKRegistry.shared.sdk(for: board.source) else { return }
        if reset {
            page = 1
            errorMessage = nil
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let res = try await sdk.getLeaderboardTracks(bangId: board.bangid, page: page)
            if reset {
                tracks = res.list
            } else {
                let existing = Set(tracks.map(\.id))
                tracks.append(contentsOf: res.list.filter { !existing.contains($0.id) })
            }
            total = res.total
            hasMore = !res.list.isEmpty && tracks.count < res.total && res.limit < 500
            page += 1
        } catch {
            if reset {
                errorMessage = error.localizedDescription
            }
        }
    }
}
