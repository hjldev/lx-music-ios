import SwiftUI

/// Modal sheet to add one or multiple tracks to an existing playlist or a newly created playlist.
struct AddToPlaylistSheet: View {
    let tracks: [MusicInfo]
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library

    @State private var showCreateAlert = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newPlaylistName = ""
                        showCreateAlert = true
                    } label: {
                        Label("新建歌单并添加", systemImage: "plus.circle.fill")
                            .font(.body.weight(.medium))
                    }
                }

                Section("选择目标歌单（共 \(tracks.count) 首）") {
                    ForEach(library.allVisibleLists) { list in
                        Button {
                            library.addTracks(tracks, to: list.id)
                            env.showToast("已添加到「\(list.displayName)」")
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: iconName(for: list.id))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(list.displayName)
                                        .foregroundStyle(.primary)
                                    Text("\(list.list.count) 首歌曲")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加到歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("新建歌单", isPresented: $showCreateAlert) {
                TextField("输入歌单名称", text: $newPlaylistName)
                Button("取消", role: .cancel) {}
                Button("创建并添加") {
                    let created = library.createUserPlaylist(name: newPlaylistName, tracks: tracks)
                    env.showToast("已创建「\(created.displayName)」")
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func iconName(for id: String) -> String {
        switch id {
        case BuiltInListID.default: return "headphones"
        case BuiltInListID.love: return "heart.fill"
        default: return "music.note.list"
        }
    }
}
