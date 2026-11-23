import SwiftUI

/// Online SongList Square (`歌单广场`) supporting all 5 music sources, sort modes, tag categories,
/// infinite pagination, and opening any external playlist by URL/ID/Kugou code.
struct SongListSquareView: View {
    let accentColor: Color
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(PlayerController.self) private var player

    @State private var selectedSource: MusicSource = .kw
    @State private var selectedSortId: String = "new"
    @State private var selectedTag: SongListTagItem? = nil

    @State private var tagsResult: SongListTagsResult?
    @State private var items: [OnlineSongListItem] = []
    @State private var page: Int = 1
    @State private var hasMore: Bool = true
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    @State private var showTagPicker = false
    @State private var showOpenLinkAlert = false
    @State private var linkInput = ""
    @State private var openLinkItem: OnlineSongListItem?

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SourcePickerBar(selected: $selectedSource, accentColor: accentColor)

                // Sort & Tag Filter Row
                HStack(spacing: 8) {
                    if let sdk = MusicSDKRegistry.shared.sdk(for: selectedSource) {
                        ForEach(sdk.songListSortOptions) { opt in
                            let isSelected = (opt.id == selectedSortId)
                            Button {
                                selectedSortId = opt.id
                                Task { await loadPage(reset: true) }
                            } label: {
                                Text(opt.name)
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? accentColor : .secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(isSelected ? accentColor.opacity(0.14) : Color.secondary.opacity(0.1))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer()

                    Button {
                        showTagPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedTag?.name ?? "全部分类")
                                .font(.caption.weight(.medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(selectedTag != nil ? accentColor : .primary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                Divider()

                contentArea
            }
            .navigationTitle("歌单广场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        linkInput = ""
                        showOpenLinkAlert = true
                    } label: {
                        Image(systemName: "link.badge.plus")
                    }
                }
            }
            .navigationDestination(for: OnlineSongListItem.self) { item in
                SongListDetailView(item: item, accentColor: accentColor)
            }
            .navigationDestination(item: $openLinkItem) { item in
                SongListDetailView(item: item, accentColor: accentColor)
            }
            .sheet(isPresented: $showTagPicker) {
                tagPickerSheet
            }
            .alert("打开在线歌单链接 / ID", isPresented: $showOpenLinkAlert) {
                TextField("粘贴 \(selectedSource.displayName) 歌单链接、ID 或酷狗码", text: $linkInput)
                Button("取消", role: .cancel) {}
                Button("打开") {
                    let trimmed = linkInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    openLinkItem = OnlineSongListItem(
                        id: trimmed,
                        name: "在线歌单",
                        author: "",
                        img: nil,
                        playCount: nil,
                        desc: nil,
                        source: selectedSource
                    )
                }
            } message: {
                Text("当前音源：\(selectedSource.displayName)")
            }
            .onChange(of: selectedSource) { _, newSource in
                settingsStore.settings.defaultDiscoverSource = newSource
                selectedTag = nil
                tagsResult = nil
                selectedSortId = MusicSDKRegistry.shared.sdk(for: newSource)?.songListSortOptions.first?.id ?? "hot"
                Task {
                    await loadTags()
                    await loadPage(reset: true)
                }
            }
            .task {
                if items.isEmpty {
                    selectedSource = settingsStore.settings.defaultDiscoverSource
                    selectedSortId = MusicSDKRegistry.shared.sdk(for: selectedSource)?.songListSortOptions.first?.id ?? "new"
                    await loadTags()
                    await loadPage(reset: true)
                }
            }
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if isLoading && items.isEmpty {
            ProgressView("加载歌单中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, items.isEmpty {
            ContentUnavailableView {
                Label("加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("重试") {
                    Task { await loadPage(reset: true) }
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items, id: \.uniqueKey) { item in
                        NavigationLink(value: item) {
                            songListCard(item)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if item.uniqueKey == items.last?.uniqueKey && hasMore && !isLoading {
                                Task { await loadPage(reset: false) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, player.currentTrack != nil ? 90 : 24)

                if isLoading && !items.isEmpty {
                    ProgressView()
                        .padding(.vertical, 16)
                }
            }
            .refreshable {
                await loadPage(reset: true)
            }
        }
    }

    private func songListCard(_ item: OnlineSongListItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                CachedAsyncImage(urlString: item.img, cornerRadius: 12, placeholderIcon: "music.note.list")
                    .aspectRatio(1, contentMode: .fit)

                if let count = item.playCount, !count.isEmpty, count != "0" {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                        Text(count)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(6)
                }
            }

            Text(item.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if !item.author.isEmpty {
                Text(item.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var tagPickerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Button {
                        selectedTag = nil
                        showTagPicker = false
                        Task { await loadPage(reset: true) }
                    } label: {
                        Text("全部歌单")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selectedTag == nil ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(selectedTag == nil ? accentColor : Color.secondary.opacity(0.14))
                            )
                    }
                    .buttonStyle(.plain)

                    if let tags = tagsResult {
                        if !tags.hotTag.isEmpty {
                            tagGroupSection(title: "热门标签", items: tags.hotTag)
                        }
                        ForEach(tags.tags) { group in
                            tagGroupSection(title: group.name, items: group.list)
                        }
                    } else {
                        ProgressView("加载分类标签...")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
                .padding(16)
            }
            .navigationTitle("选择歌单分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showTagPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func tagGroupSection(title: String, items: [SongListTagItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                ForEach(items) { tag in
                    let isSelected = (selectedTag?.id == tag.id)
                    Button {
                        selectedTag = tag
                        showTagPicker = false
                        Task { await loadPage(reset: true) }
                    } label: {
                        Text(tag.name)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? accentColor : Color.secondary.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadTags() async {
        guard let sdk = MusicSDKRegistry.shared.sdk(for: selectedSource) else { return }
        tagsResult = try? await sdk.getSongListTags()
    }

    private func loadPage(reset: Bool) async {
        guard let sdk = MusicSDKRegistry.shared.sdk(for: selectedSource) else { return }
        if reset {
            page = 1
            hasMore = true
            errorMessage = nil
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let res = try await sdk.getSongList(sortId: selectedSortId, tagId: selectedTag?.id, page: page)
            if reset {
                items = res.list
            } else {
                let existing = Set(items.map(\.uniqueKey))
                items.append(contentsOf: res.list.filter { !existing.contains($0.uniqueKey) })
            }
            hasMore = !res.list.isEmpty && items.count < res.total
            page += 1
        } catch {
            if reset {
                errorMessage = error.localizedDescription
            }
        }
    }
}
