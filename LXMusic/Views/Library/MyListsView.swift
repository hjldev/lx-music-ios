import SwiftUI
import UniformTypeIdentifiers

/// FileDocument wrapper enabling native iOS `.lxmc` export via `fileExporter`.
struct LXMCExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// My Music Library (`我的`) managing `试听列表`, `我的收藏`, custom playlists,
/// Dislike List entry, and `.lxmc` / `.json` backup import & export.
struct MyListsView: View {
    let accentColor: Color
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(DislikeStore.self) private var dislikeStore
    @Environment(PlayerController.self) private var player

    @State private var showCreateAlert = false
    @State private var newListName = ""
    @State private var renamingList: UserPlaylist? = nil
    @State private var renameText = ""

    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDoc: LXMCExportDocument?

    var body: some View {
        NavigationStack {
            List {
                // Built-in Lists
                Section("内置列表") {
                    NavigationLink(value: library.defaultList.id) {
                        playlistRow(
                            title: library.defaultList.displayName,
                            count: library.defaultList.list.count,
                            icon: "headphones",
                            iconColor: accentColor
                        )
                    }

                    NavigationLink(value: library.loveList.id) {
                        playlistRow(
                            title: library.loveList.displayName,
                            count: library.loveList.list.count,
                            icon: "heart.fill",
                            iconColor: .red
                        )
                    }

                    NavigationLink {
                        DislikeManagerView(accentColor: accentColor)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "hand.thumbsdown.fill")
                                .font(.body)
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Color.secondary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("不喜欢列表")
                                    .font(.body)
                                Text("\(dislikeStore.ruleCount) 条屏蔽规则")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Custom User Playlists
                Section {
                    if library.userLists.isEmpty {
                        Text("暂无自建歌单，点击右上角 + 创建或从歌单广场收藏")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(library.userLists) { list in
                            NavigationLink(value: list.id) {
                                playlistRow(
                                    title: list.displayName,
                                    count: list.list.count,
                                    icon: list.source != nil ? "globe.asia.australia" : "music.note.list",
                                    iconColor: accentColor,
                                    subtitleTag: list.source?.shortName
                                )
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    library.deleteUserPlaylist(id: list.id)
                                    env.showToast("已删除歌单「\(list.displayName)」")
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    renamingList = list
                                    renameText = list.name
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                        .onMove { from, to in
                            library.moveUserPlaylists(from: from, to: to)
                        }
                    }
                } header: {
                    HStack {
                        Text("自建歌单（\(library.userLists.count)）")
                        Spacer()
                        Button {
                            newListName = ""
                            showCreateAlert = true
                        } label: {
                            Label("新建", systemImage: "plus")
                                .font(.caption.weight(.medium))
                        }
                    }
                }

                // LX Music Backup Interoperability
                Section("歌单备份（兼容 LX Music 桌面端 .lxmc）") {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入 .lxmc / .json 歌单备份", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        do {
                            let data = try library.exportAllBackupData()
                            exportDoc = LXMCExportDocument(data: data)
                            showExporter = true
                        } catch {
                            env.showToast("导出失败：\(error.localizedDescription)")
                        }
                    } label: {
                        Label("导出全部歌单 (.lxmc)", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("我的歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !library.userLists.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newListName = ""
                        showCreateAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: String.self) { listId in
                PlaylistDetailView(listId: listId, accentColor: accentColor)
            }
            .safeAreaInset(edge: .bottom) {
                if player.currentTrack != nil {
                    Color.clear.frame(height: 76)
                }
            }
            .alert("新建歌单", isPresented: $showCreateAlert) {
                TextField("输入歌单名称", text: $newListName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let created = library.createUserPlaylist(name: newListName)
                    env.showToast("已创建歌单「\(created.displayName)」")
                }
            }
            .alert("重命名歌单", isPresented: Binding(
                get: { renamingList != nil },
                set: { if !$0 { renamingList = nil } }
            )) {
                TextField("新的歌单名称", text: $renameText)
                Button("取消", role: .cancel) { renamingList = nil }
                Button("保存") {
                    if let target = renamingList {
                        library.renameUserPlaylist(id: target.id, newName: renameText)
                    }
                    renamingList = nil
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.data, .json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .fileExporter(
                isPresented: $showExporter,
                document: exportDoc,
                contentType: .data,
                defaultFilename: "lx_list.lxmc"
            ) { result in
                if case .success = result {
                    env.showToast("歌单备份已导出")
                }
            }
        }
    }

    private func playlistRow(title: String, count: Int, icon: String, iconColor: Color, subtitleTag: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(iconColor.gradient, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                HStack(spacing: 6) {
                    Text("\(count) 首歌曲")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let tag = subtitleTag {
                        Text("关联 \(tag)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(accentColor)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let count = try library.importBackup(data: data)
                env.showToast("导入成功，共 \(count) 首歌曲")
            } catch {
                env.showToast("导入失败：\(error.localizedDescription)")
            }
        case .failure(let error):
            env.showToast("选择文件失败：\(error.localizedDescription)")
        }
    }
}
