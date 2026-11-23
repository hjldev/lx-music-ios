import SwiftUI
import UniformTypeIdentifiers

/// Main Settings screen covering Custom Source JS Engine, Audio Quality, Playback, Lyrics,
/// Dislike Rules, Data Backup, Cache Management, and About.
struct SettingsView: View {
    let accentColor: Color
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(UserApiStore.self) private var userApiStore
    @Environment(LibraryStore.self) private var library
    @Environment(DislikeStore.self) private var dislikeStore
    @Environment(PlayerController.self) private var player

    @State private var showClearCacheConfirm = false
    @State private var showBackupImporter = false
    @State private var showBackupExporter = false
    @State private var exportDoc: LXMCExportDocument?

    var body: some View {
        @Bindable var bindableSettings = settingsStore

        NavigationStack {
            Form {
                // Custom Source Status Banner (most critical config for LX Music v2)
                Section("自定义音源（播放必配）") {
                    NavigationLink {
                        UserApiManagerView(accentColor: accentColor)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: statusIcon)
                                .font(.title2)
                                .foregroundStyle(statusColor)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(userApiStore.activeScript?.name ?? "未配置自定义音源脚本")
                                    .font(.body.weight(.semibold))
                                Text(statusDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Playback Settings
                Section("播放与音质") {
                    Picker("优先播放音质", selection: $bindableSettings.settings.playQuality) {
                        ForEach(AudioQuality.selectableQualities) { q in
                            Text(q.displayName).tag(q)
                        }
                    }

                    Picker("播放模式", selection: $bindableSettings.settings.playMode) {
                        ForEach(PlayMode.allCases) { m in
                            Label(m.displayName, systemImage: m.systemImage).tag(m)
                        }
                    }

                    Toggle("播放失败自动换源", isOn: $bindableSettings.settings.allowAutoSwitchSource)
                    Toggle("出错时自动跳过下一首", isOn: $bindableSettings.settings.autoSkipOnError)
                    Toggle("切歌单时清空随机历史", isOn: $bindableSettings.settings.isAutoCleanPlayedList)
                    Toggle("定时关闭前播完当前曲目", isOn: $bindableSettings.settings.waitPlayEndStop)
                }

                // Lyric Settings
                Section("歌词显示") {
                    Toggle("逐字卡拉OK高亮 (lxlyric)", isOn: $bindableSettings.settings.isPlayLxlrc)
                        .onChange(of: settingsStore.settings.isPlayLxlrc) { _, _ in player.rebuildLyricsFromSettings() }

                    Toggle("显示翻译歌词", isOn: $bindableSettings.settings.isShowLyricTranslation)
                        .onChange(of: settingsStore.settings.isShowLyricTranslation) { _, _ in player.rebuildLyricsFromSettings() }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("歌词字号")
                            Spacer()
                            Text("\(Int(settingsStore.settings.lyricFontSize)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $bindableSettings.settings.lyricFontSize, in: 14...26, step: 1)
                            .tint(accentColor)
                    }
                }

                // Status Bar & Lock Screen Lyrics
                Section("状态栏与锁屏歌词") {
                    Toggle("应用内状态栏歌词悬浮条", isOn: $bindableSettings.settings.enableStatusBarLyric)

                    Toggle("系统锁屏滚动歌词", isOn: $bindableSettings.settings.enableLockScreenLyric)
                        .onChange(of: settingsStore.settings.enableLockScreenLyric) { _, _ in
                            player.refreshNowPlayingMetadata()
                        }

                    if settingsStore.settings.enableLockScreenLyric {
                        Picker("锁屏展示模式", selection: $bindableSettings.settings.lockScreenLyricMode) {
                            ForEach(LockScreenLyricMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .onChange(of: settingsStore.settings.lockScreenLyricMode) { _, _ in
                            player.refreshNowPlayingMetadata()
                        }

                        if settingsStore.settings.lockScreenLyricMode != .titleOnly {
                            Picker("海报封面歌词行数", selection: $bindableSettings.settings.lockScreenLyricLines) {
                                Text("3 行（当前句 + 上下句）").tag(3)
                                Text("1 行（仅当前高亮句）").tag(1)
                            }
                            .onChange(of: settingsStore.settings.lockScreenLyricLines) { _, _ in
                                player.refreshNowPlayingMetadata()
                            }
                        }
                    }
                }

                // Data, Dislike & Cache
                Section("数据与缓存") {
                    NavigationLink {
                        DislikeManagerView(accentColor: accentColor)
                    } label: {
                        HStack {
                            Text("不喜欢列表规则")
                            Spacer()
                            Text("\(dislikeStore.ruleCount) 条")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        showBackupImporter = true
                    } label: {
                        Label("导入歌单备份 (.lxmc / .json)", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        if let data = try? library.exportAllBackupData() {
                            exportDoc = LXMCExportDocument(data: data)
                            showBackupExporter = true
                        }
                    } label: {
                        Label("导出全部歌单备份 (.lxmc)", systemImage: "square.and.arrow.up")
                    }

                    Button(role: .destructive) {
                        showClearCacheConfirm = true
                    } label: {
                        HStack {
                            Text("清理缓存（歌词/封面/播放链接）")
                            Spacer()
                            Text(settingsStore.cacheSizeText)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // About
                Section("关于") {
                    HStack {
                        Text("应用版本")
                        Spacer()
                        Text("LX Music iOS 2.12.6")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("引擎架构")
                        Spacer()
                        Text("纯原生 SwiftUI + JavaScriptCore")
                            .foregroundStyle(.secondary)
                    }
                    Text("基于 lx-music-desktop 核心业务逻辑构建，遵循 Apache-2.0 开源协议。本软件仅提供音频检索与脚本运行环境，不内置任何受版权保护的音频解析接口。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if player.currentTrack != nil {
                    Color.clear.frame(height: 76)
                }
            }
            .onAppear {
                settingsStore.refreshCacheSize()
            }
            .confirmationDialog("确认清理全部歌词、图片及链接缓存？", isPresented: $showClearCacheConfirm, titleVisibility: .visible) {
                Button("立即清理", role: .destructive) {
                    settingsStore.clearCache()
                    env.showToast("缓存已清理")
                }
                Button("取消", role: .cancel) {}
            }
            .fileImporter(isPresented: $showBackupImporter, allowedContentTypes: [.data, .json]) { result in
                if case .success(let url) = result {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url),
                       let count = try? library.importBackup(data: data) {
                        env.showToast("成功导入 \(count) 首歌曲")
                    } else {
                        env.showToast("备份文件解析失败")
                    }
                }
            }
            .fileExporter(
                isPresented: $showBackupExporter,
                document: exportDoc,
                contentType: .data,
                defaultFilename: "lx_list.lxmc"
            ) { result in
                if case .success = result {
                    env.showToast("备份已导出")
                }
            }
        }
    }

    private var statusIcon: String {
        if userApiStore.activeScript == nil { return "exclamationmark.circle.fill" }
        if userApiStore.runtimeStatus.isInitializing { return "hourglass.circle.fill" }
        return userApiStore.runtimeStatus.isInitialized ? "checkmark.seal.fill" : "xmark.octagon.fill"
    }

    private var statusColor: Color {
        if userApiStore.activeScript == nil { return .orange }
        if userApiStore.runtimeStatus.isInitializing { return .blue }
        return userApiStore.runtimeStatus.isInitialized ? .green : .red
    }

    private var statusDescription: String {
        if userApiStore.activeScript == nil {
            return "点击导入兼容 LX Music v2 的 .js 自定义音源脚本"
        }
        if userApiStore.runtimeStatus.isInitializing {
            return "正在初始化 JavaScriptCore 音源引擎..."
        }
        if userApiStore.runtimeStatus.isInitialized {
            let names = MusicSource.onlineSources
                .filter { userApiStore.runtimeStatus.sources[$0] != nil }
                .map(\.shortName)
                .joined(separator: " / ")
            return "运行正常 · 支持：\(names.isEmpty ? "无" : names)"
        }
        return userApiStore.runtimeStatus.message ?? "初始化失败"
    }
}
