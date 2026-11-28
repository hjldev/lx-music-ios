import Foundation
import Observation

@Observable
@MainActor
final class SettingsStore {
    var settings: AppSettings {
        didSet {
            PersistenceStore.shared.saveSettings(settings)
        }
    }

    var cacheSizeText: String = "计算中..."

    init() {
        self.settings = PersistenceStore.shared.loadSettings()
        refreshCacheSize()
    }

    func refreshCacheSize() {
        Task.detached(priority: .utility) {
            let bytes = PersistenceStore.shared.calculateCacheSizeBytes()
            let formatted = FormatUtils.sizeFormate(bytes)
            await MainActor.run {
                self.cacheSizeText = formatted
            }
        }
    }

    func clearCache() {
        PersistenceStore.shared.clearAllCaches()
        CrossSourceMatcher.shared.clearCache()
        refreshCacheSize()
    }
}
