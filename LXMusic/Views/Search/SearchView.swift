import SwiftUI

/// Kuwo Music Search (`搜索`) supporting Music & SongList search,
/// real-time search suggestions (`tipSearch`), hot search words (`hotSearch`), and persistent search history.
struct SearchView: View {
    let accentColor: Color
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player

    enum SearchMode: String, CaseIterable {
        case music = "歌曲"
        case songList = "歌单"
    }

    @State private var searchText: String = ""
    @State private var mode: SearchMode = .music

    @State private var musicResults: [MusicInfo] = []
    @State private var songListResults: [OnlineSongListItem] = []
    @State private var hotWords: [String] = []
    @State private var tipSuggestions: [String] = []

    @State private var page: Int = 1
    @State private var hasMore: Bool = false
    @State private var isSearching: Bool = false
    @State private var hasExecutedSearch: Bool = false
    @State private var errorMessage: String?

    @State private var tipTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private var sdk: KWMusicSDK {
        MusicSDKRegistry.shared.kw
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search Input Bar
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索歌曲、歌手、专辑或歌单...", text: $searchText)
                            .textFieldStyle(.plain)
                            .submitLabel(.search)
                            .focused($isSearchFocused)
                            .onSubmit {
                                executeSearch(query: searchText)
                            }
                            .onChange(of: searchText) { _, newValue in
                                handleTypingChange(newValue)
                            }

                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                                tipSuggestions = []
                                hasExecutedSearch = false
                                musicResults = []
                                songListResults = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                    if !searchText.isEmpty {
                        Button("搜索") {
                            isSearchFocused = false
                            executeSearch(query: searchText)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accentColor)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)

                Picker("搜索类型", selection: $mode) {
                    ForEach(SearchMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .onChange(of: mode) { _, _ in
                    if hasExecutedSearch && !searchText.isEmpty {
                        executeSearch(query: searchText)
                    }
                }

                Divider()

                mainBody
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: OnlineSongListItem.self) { item in
                SongListDetailView(item: item, accentColor: accentColor)
            }
            .task {
                if hotWords.isEmpty {
                    await loadHotSearch()
                }
            }
        }
    }

    @ViewBuilder
    private var mainBody: some View {
        if isSearchFocused && !tipSuggestions.isEmpty && !hasExecutedSearch {
            List(tipSuggestions, id: \.self) { suggestion in
                Button {
                    searchText = suggestion
                    isSearchFocused = false
                    executeSearch(query: suggestion)
                } label: {
                    Label(suggestion, systemImage: "magnifyingglass")
                        .foregroundStyle(.primary)
                }
            }
            .listStyle(.plain)
        } else if !hasExecutedSearch {
            discoveryLandingView
        } else if isSearching && musicResults.isEmpty && songListResults.isEmpty {
            ProgressView("正在搜索...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, musicResults.isEmpty && songListResults.isEmpty {
            ContentUnavailableView("搜索失败", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if mode == .music {
            musicResultsList
        } else {
            songListResultsList
        }
    }

    private var discoveryLandingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !library.searchHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("搜索历史")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("清空") {
                                library.clearSearchHistory()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        FlowTagLayout(spacing: 8) {
                            ForEach(library.searchHistory, id: \.self) { word in
                                Button {
                                    searchText = word
                                    executeSearch(query: word)
                                } label: {
                                    Text(word)
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.secondary.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        library.removeSearchHistory(word)
                                    } label: {
                                        Label("删除此记录", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }

                if !hotWords.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("热门搜索")
                            .font(.subheadline.weight(.semibold))

                        FlowTagLayout(spacing: 8) {
                            ForEach(Array(hotWords.prefix(24).enumerated()), id: \.offset) { idx, word in
                                Button {
                                    searchText = word
                                    executeSearch(query: word)
                                } label: {
                                    HStack(spacing: 4) {
                                        if idx < 3 {
                                            Text("\(idx + 1)")
                                                .font(.caption2.bold())
                                                .foregroundStyle(accentColor)
                                        }
                                        Text(word)
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(idx < 3 ? accentColor.opacity(0.12) : Color.secondary.opacity(0.1))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, player.currentTrack != nil ? 80 : 16)
        }
    }

    @ViewBuilder
    private var musicResultsList: some View {
        if musicResults.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(Array(musicResults.enumerated()), id: \.element.id) { idx, track in
                    MusicRowView(
                        track: track,
                        index: nil,
                        showSourceBadge: true,
                        accentColor: accentColor
                    ) {
                        player.playAdHoc(tracks: musicResults, startIndex: idx)
                    }
                    .onAppear {
                        if idx == musicResults.count - 1 && hasMore && !isSearching {
                            Task { await performSearchPage(reset: false) }
                        }
                    }
                }
                if isSearching {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
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

    @ViewBuilder
    private var songListResultsList: some View {
        if songListResults.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(songListResults, id: \.uniqueKey) { item in
                    NavigationLink(value: item) {
                        HStack(spacing: 12) {
                            CachedAsyncImage(urlString: item.img, cornerRadius: 8, placeholderIcon: "music.note.list")
                                .frame(width: 54, height: 54)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .font(.body)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(item.source.shortName)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(accentColor)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                                    if !item.author.isEmpty {
                                        Text(item.author)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    if let total = item.total, total > 0 {
                                        Text("\(total)首")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .onAppear {
                        if item.uniqueKey == songListResults.last?.uniqueKey && hasMore && !isSearching {
                            Task { await performSearchPage(reset: false) }
                        }
                    }
                }
                if isSearching {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
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

    // MARK: - Search Execution

    private func handleTypingChange(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            tipSuggestions = []
            hasExecutedSearch = false
            return
        }
        hasExecutedSearch = false
        tipTask?.cancel()
        tipTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            if let tips = try? await sdk.getTipSearch(query: trimmed),
               !Task.isCancelled {
                tipSuggestions = Array(tips.prefix(10))
            }
        }
    }

    private func loadHotSearch() async {
        if let words = try? await sdk.getHotSearch() {
            hotWords = words
        }
    }

    private func executeSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        library.addSearchHistory(trimmed)
        tipSuggestions = []
        hasExecutedSearch = true
        Task { await performSearchPage(reset: true) }
    }

    private func performSearchPage(reset: Bool) async {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if reset {
            page = 1
            errorMessage = nil
            musicResults = []
            songListResults = []
        }
        isSearching = true
        defer { isSearching = false }

        do {
            if mode == .music {
                let res = try await sdk.searchMusic(query: trimmed, page: page, limit: 30)
                let existing = Set(musicResults.map(\.id))
                musicResults.append(contentsOf: res.list.filter { !existing.contains($0.id) })
                hasMore = page < res.allPage && !res.list.isEmpty
                page += 1
            } else {
                let res = try await sdk.searchSongList(query: trimmed, page: page, limit: 20)
                let existing = Set(songListResults.map(\.uniqueKey))
                songListResults.append(contentsOf: res.list.filter { !existing.contains($0.uniqueKey) })
                hasMore = songListResults.count < res.total && !res.list.isEmpty
                page += 1
            }
        } catch {
            if reset {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Native SwiftUI flow-wrapping tag layout for Hot Search & Search History chips.
struct FlowTagLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
