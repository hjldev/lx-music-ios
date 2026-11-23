import SwiftUI
import UniformTypeIdentifiers

/// Full LX Music v2 Custom Source Script Manager (`自定义音源管理`).
/// Supports importing `.js` scripts from Files, HTTP/HTTPS URL, or clipboard/text paste.
struct UserApiManagerView: View {
    let accentColor: Color
    @Environment(AppEnvironment.self) private var env
    @Environment(UserApiStore.self) private var userApiStore

    @State private var showFileImporter = false
    @State private var showURLAlert = false
    @State private var urlInput = ""
    @State private var isDownloadingURL = false

    @State private var showPasteSheet = false
    @State private var pastedCode = ""
    @State private var importError: String?

    var body: some View {
        List {
            // Runtime Status Section
            if let active = userApiStore.activeScript {
                Section("当前运行状态") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(active.name)
                                .font(.headline)
                            if !active.version.isEmpty {
                                Text("v\(active.version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if userApiStore.runtimeStatus.isInitializing {
                                ProgressView().scaleEffect(0.85)
                            } else {
                                Text(userApiStore.runtimeStatus.isInitialized ? "已就绪" : "异常")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(userApiStore.runtimeStatus.isInitialized ? .green : .red)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        (userApiStore.runtimeStatus.isInitialized ? Color.green : Color.red).opacity(0.14),
                                        in: Capsule()
                                    )
                            }
                        }

                        if let msg = userApiStore.runtimeStatus.message, !msg.isEmpty {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if userApiStore.runtimeStatus.isInitialized {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(MusicSource.onlineSources) { src in
                                    if let cap = userApiStore.runtimeStatus.sources[src] {
                                        HStack(spacing: 6) {
                                            Text(src.displayName)
                                                .font(.caption.weight(.medium))
                                                .frame(width: 62, alignment: .leading)
                                            ForEach(cap.qualitys) { q in
                                                Text(q.rawValue)
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(accentColor)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(accentColor.opacity(0.12), in: Capsule())
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }

                        HStack(spacing: 12) {
                            Button("重新初始化") {
                                userApiStore.reloadActiveScript()
                            }
                            .font(.caption.weight(.medium))

                            Button("停用当前音源", role: .destructive) {
                                userApiStore.activate(scriptId: nil)
                            }
                            .font(.caption.weight(.medium))
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
            }

            // Import Methods
            Section("导入自定义音源脚本 (LX Music v2 .js)") {
                Button {
                    showFileImporter = true
                } label: {
                    Label("从「文件」导入 .js 脚本", systemImage: "doc.badge.plus")
                }

                Button {
                    urlInput = ""
                    showURLAlert = true
                } label: {
                    HStack {
                        Label("通过网络链接 (URL) 导入", systemImage: "link.badge.plus")
                        if isDownloadingURL {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isDownloadingURL)

                Button {
                    pastedCode = ""
                    showPasteSheet = true
                } label: {
                    Label("粘贴脚本文本导入", systemImage: "doc.on.clipboard")
                }
            }

            // Installed Scripts
            Section("已导入脚本（\(userApiStore.scripts.count)）") {
                if userApiStore.scripts.isEmpty {
                    Text("尚未导入任何音源脚本。\nLX Music 原生 iOS 内置了 JavaScriptCore 引擎，完整支持 globalThis.lx (v2.0.0) 规范的自定义音源脚本。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(userApiStore.scripts) { script in
                        let isActive = (script.id == userApiStore.activeScriptId)
                        Button {
                            userApiStore.activate(scriptId: script.id)
                            env.showToast("已切换至「\(script.name)」")
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isActive ? accentColor : .secondary)
                                    .font(.title3)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(script.name)
                                            .font(.body.weight(isActive ? .semibold : .regular))
                                            .foregroundStyle(.primary)
                                        if !script.version.isEmpty {
                                            Text(script.version)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if !script.description.isEmpty {
                                        Text(script.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    if !script.author.isEmpty {
                                        Text("作者：\(script.author)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                userApiStore.delete(scriptId: script.id)
                                env.showToast("已删除「\(script.name)」")
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("自定义音源")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.javaScript, .sourceCode, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let code = try String(contentsOf: url, encoding: .utf8)
                    let imported = try userApiStore.importScript(rawCode: code)
                    env.showToast("已导入并启用「\(imported.name)」")
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let err):
                importError = err.localizedDescription
            }
        }
        .alert("在线导入自定义音源", isPresented: $showURLAlert) {
            TextField("https://example.com/lx-source.js", text: $urlInput)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("取消", role: .cancel) {}
            Button("下载并导入") {
                Task { await importFromURL() }
            }
        } message: {
            Text("输入兼容 LX Music v2 的 .js 脚本直链")
        }
        .sheet(isPresented: $showPasteSheet) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("请粘贴以 `/* @name ... */` 开头的 LX Music v2 自定义音源 JS 脚本：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)

                    TextEditor(text: $pastedCode)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                .navigationTitle("粘贴脚本导入")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showPasteSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入") {
                            do {
                                let imported = try userApiStore.importScript(rawCode: pastedCode)
                                showPasteSheet = false
                                env.showToast("已导入并启用「\(imported.name)」")
                            } catch {
                                importError = error.localizedDescription
                            }
                        }
                        .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func importFromURL() async {
        isDownloadingURL = true
        defer { isDownloadingURL = false }
        do {
            let imported = try await userApiStore.importScript(fromURL: urlInput)
            env.showToast("已导入并启用「\(imported.name)」")
        } catch {
            importError = error.localizedDescription
        }
    }
}
