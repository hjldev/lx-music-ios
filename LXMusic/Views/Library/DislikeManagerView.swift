import SwiftUI

/// Manages LX Music Dislike rules (`歌名@歌手`, `歌名`, `@歌手`; `#` escapes literal `@`).
struct DislikeManagerView: View {
    let accentColor: Color
    @Environment(AppEnvironment.self) private var env
    @Environment(DislikeStore.self) private var dislikeStore

    @State private var showAddSheet = false
    @State private var showBatchEditSheet = false
    @State private var songInput = ""
    @State private var singerInput = ""
    @State private var batchRulesText = ""
    @State private var showClearConfirm = false

    var body: some View {
        List {
            Section {
                Text("支持三种规则格式：\n• 歌名@歌手 — 屏蔽指定歌曲\n• 歌名 — 屏蔽任意歌手的同名歌曲\n• @歌手 — 屏蔽该歌手全部歌曲\n注：若名称本身包含 @，请替换为 #。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("规则说明（与 LX Music 桌面端完全一致）")
            }

            Section {
                if dislikeStore.ruleLines.isEmpty {
                    Text("暂无不喜欢规则")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dislikeStore.ruleLines, id: \.self) { rule in
                        Text(rule)
                            .font(.body)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    dislikeStore.removeRule(rule)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Text("已生效规则（\(dislikeStore.ruleCount)）")
            }
        }
        .navigationTitle("不喜欢列表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    batchRulesText = dislikeStore.rulesText
                    showBatchEditSheet = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }

                Button {
                    songInput = ""
                    singerInput = ""
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }

                if dislikeStore.ruleCount > 0 {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .alert("添加不喜欢规则", isPresented: $showAddSheet) {
            TextField("歌曲名（可留空）", text: $songInput)
            TextField("歌手名（可留空）", text: $singerInput)
            Button("取消", role: .cancel) {}
            Button("添加") {
                dislikeStore.addDislike(name: songInput, singer: singerInput)
                env.showToast("规则已添加")
            }
        }
        .sheet(isPresented: $showBatchEditSheet) {
            NavigationStack {
                TextEditor(text: $batchRulesText)
                    .font(.body.monospaced())
                    .padding(12)
                    .navigationTitle("批量编辑规则（每行一条）")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showBatchEditSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                dislikeStore.updateRules(batchRulesText)
                                showBatchEditSheet = false
                                env.showToast("已保存 \(dislikeStore.ruleCount) 条规则")
                            }
                        }
                    }
            }
        }
        .confirmationDialog("确认清空全部不喜欢规则？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空全部", role: .destructive) {
                dislikeStore.clearAll()
            }
            Button("取消", role: .cancel) {}
        }
    }
}
