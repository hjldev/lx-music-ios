import Foundation

/// Exact port of `src/main/modules/userApi/utils.ts:parseScriptInfo` for extracting
/// `@name`, `@description`, `@version`, `@author`, `@homepage` from LX Music v2 custom source JS scripts.
enum UserApiHeaderParser {

    struct ParsedHeader: Equatable, Sendable {
        var name: String
        var description: String
        var version: String
        var author: String
        var homepage: String
    }

    enum ParserError: LocalizedError {
        case invalidScriptHeader
        var errorDescription: String? { "无效的自定义源文件（文件头部缺少 /* ... */ 元信息注释块）" }
    }

    private static let maxLengths: [String: Int] = [
        "name": 24,
        "description": 36,
        "author": 56,
        "homepage": 1024,
        "version": 36,
    ]

    static func parse(_ rawScript: String) throws -> ParsedHeader {
        var script = rawScript
        if script.hasPrefix("\u{FEFF}") {
            script.removeFirst()
        }

        guard let headerMatch = RegexHelper.firstMatch(#"^\/\*[\S\s]+?\*\/"#, in: script),
              let block = headerMatch.first else {
            throw ParserError.invalidScriptHeader
        }

        var values: [String: String] = [
            "name": "",
            "description": "",
            "version": "",
            "author": "",
            "homepage": "",
        ]

        let lines = block.components(separatedBy: CharacterSet.newlines)
        for line in lines {
            guard let m = RegexHelper.firstMatch(#"^\s?\*\s?@(\w+)\s(.+)$"#, in: line),
                  m.count >= 3 else { continue }
            let key = m[1]
            guard let limit = maxLengths[key] else { continue }
            var val = m[2].trimmingCharacters(in: .whitespacesAndNewlines)
            if val.count > limit {
                val = String(val.prefix(limit)) + "..."
            }
            values[key] = val
        }

        var name = values["name"] ?? ""
        if name.isEmpty {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy/MM/dd HH:mm:ss"
            name = "user_api_\(fmt.string(from: Date()))"
        }

        return ParsedHeader(
            name: name,
            description: values["description"] ?? "",
            version: values["version"] ?? "",
            author: values["author"] ?? "",
            homepage: values["homepage"] ?? ""
        )
    }

    static func makeScriptId() -> String {
        let rand = Int.random(in: 100...999)
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        return "user_api_\(rand)_\(ts)"
    }
}
