import Foundation
import Observation

/// Manages LX Music v2 custom source JavaScript scripts and coordinates the `UserApiEngine`.
@Observable
@MainActor
final class UserApiStore {
    private(set) var scripts: [UserApiScript] = []
    private(set) var activeScriptId: String?
    private(set) var runtimeStatus: UserApiRuntimeStatus = .idle
    var pendingUpdateAlert: UserApiUpdateAlert?

    private let engine = UserApiEngine()
    private unowned let settingsStore: SettingsStore

    var activeScript: UserApiScript? {
        guard let id = activeScriptId else { return nil }
        return scripts.first(where: { $0.id == id })
    }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.scripts = PersistenceStore.shared.loadUserApis()
        self.activeScriptId = settingsStore.settings.activeUserApiId

        engine.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.runtimeStatus = status
            }
        }
        engine.onUpdateAlert = { [weak self] alert in
            Task { @MainActor in
                self?.pendingUpdateAlert = alert
            }
        }

        if let active = activeScript {
            engine.load(script: active)
        } else if activeScriptId != nil {
            activeScriptId = nil
            settingsStore.settings.activeUserApiId = nil
        }
    }

    // MARK: - Import / Manage Scripts

    @discardableResult
    func importScript(rawCode: String, autoActivate: Bool = true) throws -> UserApiScript {
        let header = try UserApiHeaderParser.parse(rawCode)

        // Deduplicate by exact script content (matching desktop `userApi/utils.ts`)
        if let existing = scripts.first(where: { $0.script == rawCode }) {
            if autoActivate {
                activate(scriptId: existing.id)
            }
            return existing
        }

        let item = UserApiScript(
            id: UserApiHeaderParser.makeScriptId(),
            name: header.name,
            description: header.description,
            version: header.version,
            author: header.author,
            homepage: header.homepage,
            script: rawCode,
            allowShowUpdateAlert: true
        )
        scripts.insert(item, at: 0)
        PersistenceStore.shared.saveUserApis(scripts)

        if autoActivate || activeScriptId == nil {
            activate(scriptId: item.id)
        }
        return item
    }

    @discardableResult
    func importScript(fromURL urlString: String) async throws -> UserApiScript {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            throw HTTPClientError.invalidURL(trimmed)
        }
        let resp = try await HTTPClient.shared.get(trimmed, timeout: 30)
        guard resp.statusCode == 200 else {
            throw HTTPClientError.httpStatus(resp.statusCode, "下载音源脚本失败")
        }
        return try importScript(rawCode: resp.text, autoActivate: true)
    }

    func activate(scriptId: String?) {
        activeScriptId = scriptId
        settingsStore.settings.activeUserApiId = scriptId
        PersistenceStore.shared.clearMusicUrlCache()

        if let scriptId, let script = scripts.first(where: { $0.id == scriptId }) {
            engine.load(script: script)
        } else {
            engine.unload()
        }
    }

    func reloadActiveScript() {
        if let script = activeScript {
            engine.load(script: script)
        }
    }

    func delete(scriptId: String) {
        scripts.removeAll { $0.id == scriptId }
        PersistenceStore.shared.saveUserApis(scripts)
        if activeScriptId == scriptId {
            activate(scriptId: scripts.first?.id)
        }
    }

    func setAllowUpdateAlert(scriptId: String, allow: Bool) {
        guard let idx = scripts.firstIndex(where: { $0.id == scriptId }) else { return }
        scripts[idx].allowShowUpdateAlert = allow
        PersistenceStore.shared.saveUserApis(scripts)
    }

    // MARK: - Playback Query API

    func supportsSource(_ source: MusicSource) -> Bool {
        guard runtimeStatus.isInitialized, let cap = runtimeStatus.sources[source] else { return false }
        return cap.actions.contains(.musicUrl)
    }

    func supportedQualities(for source: MusicSource) -> [AudioQuality] {
        runtimeStatus.sources[source]?.qualitys ?? []
    }

    func requestMusicUrl(source: MusicSource, quality: AudioQuality, musicInfo: MusicInfo) async throws -> String {
        guard activeScript != nil else {
            throw MusicSDKError.noActiveCustomSource
        }
        guard runtimeStatus.isInitialized else {
            throw MusicSDKError.apiError(runtimeStatus.message ?? "自定义音源尚未就绪")
        }
        guard supportsSource(source) else {
            throw MusicSDKError.customSourceNotSupported(source)
        }
        return try await engine.requestMusicUrl(source: source, quality: quality, musicInfo: musicInfo)
    }
}
