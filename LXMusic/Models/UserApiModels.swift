import Foundation

/// Actions supported by a custom source (`userApi`) script.
enum UserApiAction: String, Codable, Hashable, Sendable {
    case musicUrl
    case lyric
    case pic
}

/// Per-source capability registered by a custom source script via `lx.send('inited', ...)`.
struct UserApiSourceCapability: Codable, Hashable, Sendable {
    var type: String // "music"
    var actions: [UserApiAction]
    var qualitys: [AudioQuality]
}

/// Stored LX Music v2 custom source JavaScript script with parsed header annotations.
struct UserApiScript: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String
    var version: String
    var author: String
    var homepage: String
    /// Raw JS source code (stored gzip-compressed on disk by PersistenceStore).
    var script: String
    var allowShowUpdateAlert: Bool
    var createdAt: Date

    init(
        id: String,
        name: String,
        description: String = "",
        version: String = "",
        author: String = "",
        homepage: String = "",
        script: String,
        allowShowUpdateAlert: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.homepage = homepage
        self.script = script
        self.allowShowUpdateAlert = allowShowUpdateAlert
        self.createdAt = createdAt
    }
}

/// Live runtime status of the currently active custom source script.
struct UserApiRuntimeStatus: Equatable, Sendable {
    var isInitialized: Bool
    var isInitializing: Bool
    var message: String?
    var sources: [MusicSource: UserApiSourceCapability]

    static let idle = UserApiRuntimeStatus(isInitialized: false, isInitializing: false, message: nil, sources: [:])
}

/// Update alert sent by a custom source script via `lx.send('updateAlert', ...)`.
struct UserApiUpdateAlert: Identifiable, Equatable, Sendable {
    let id = UUID()
    let scriptName: String
    let log: String
    let updateUrl: String?
}
