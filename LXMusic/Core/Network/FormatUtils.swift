import Foundation

/// Shared formatting and text-decoding helpers ported from `src/common/utils/common.ts`,
/// `src/renderer/utils/index.ts`, `src/renderer/utils/musicSdk/utils.js`, and `src/common/utils/lyricUtils/util.ts`.
enum FormatUtils {

    /// Exact port of `sizeFormate` (`B`, `KiB`, `MiB`, `GiB`, `TiB`).
    static func sizeFormate(_ size: Int64?) -> String {
        guard let size, size > 0 else { return "0 B" }
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        let idx = min(units.count - 1, max(0, Int(floor(log(Double(size)) / log(1024.0)))))
        let value = Double(size) / pow(1024.0, Double(idx))
        return String(format: "%.2f %@", value, units[idx])
    }

    /// Exact port of `formatPlayTime` (seconds -> `MM:SS`, or `--/--` if 0).
    static func formatPlayTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "--/--" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        if m == 0 && s == 0 { return "--/--" }
        return String(format: "%02d:%02d", m, s)
    }

    static func formatPlayTime(_ seconds: Int) -> String {
        formatPlayTime(Double(seconds))
    }

    /// Format player progress bar timestamps (`00:00` even at 0).
    static func formatClockTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// Parses `"MM:SS"` or `"HH:MM:SS"` into seconds (matching `getIntv`).
    static func parseIntervalSeconds(_ interval: String?) -> Int {
        guard let interval, !interval.isEmpty, interval != "--/--" else { return 0 }
        let parts = interval.split(separator: ":")
        var total = 0
        var unit = 1
        for part in parts.reversed() {
            if let v = Int(part.trimmingCharacters(in: .whitespaces)) {
                total += v * unit
            }
            unit *= 60
        }
        return total
    }

    /// Exact port of `formatPlayCount` (`万` / `亿`).
    static func formatPlayCount(_ num: Int64) -> String {
        if num > 100_000_000 {
            let v = Double(num / 10_000_000) / 10.0
            return "\(formatCompactDecimal(v))亿"
        } else if num > 10_000 {
            let v = Double(num / 1_000) / 10.0
            return "\(formatCompactDecimal(v))万"
        }
        return String(num)
    }

    private static func formatCompactDecimal(_ v: Double) -> String {
        if v.rounded() == v {
            return String(Int64(v))
        }
        return String(format: "%.1f", v)
    }

    /// Formats a timestamp (ms) or date string as `YYYY-MM-DD`.
    static func formatDateYMD(milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000.0)
        return formatDateYMD(date)
    }

    static func formatDateYMD(_ date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    static func formatDateYMD(fromString raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        if raw.count >= 10 {
            let prefix10 = String(raw.prefix(10))
            if prefix10.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                return prefix10
            }
        }
        if let ms = Int64(raw) {
            return formatDateYMD(milliseconds: ms > 10_000_000_000 ? ms : ms * 1000)
        }
        return raw
    }

    /// Joins singer arrays using `"、"` and decodes HTML entities (`formatSingerName`).
    static func formatSingerName(_ singers: [[String: Any]]?, nameKey: String = "name", join: String = "、") -> String {
        guard let singers else { return "" }
        let names = singers.compactMap { dict -> String? in
            guard let s = dict[nameKey] as? String, !s.isEmpty else { return nil }
            return s
        }
        return decodeName(names.joined(separator: join))
    }

    /// Decodes HTML entities (named + decimal + hex) and strips HTML tags (`decodeName` in `renderer/utils/index.ts`).
    static func decodeName(_ raw: String?) -> String {
        guard var str = raw, !str.isEmpty else { return "" }

        // Strip common highlight HTML tags (e.g. <em>...</em>) without touching literal angle brackets inside song titles unless tag-shaped.
        str = str.replacingOccurrences(of: #"</?(?:em|b|i|span|strong|font|a|br)\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])

        return decodeHTMLEntities(str)
    }

    /// Lyric-safe entity decoder matching `src/common/utils/lyricUtils/util.ts` (never strips `<start,dur>` timing tags!).
    static func decodeLyricEntities(_ raw: String?) -> String {
        guard let str = raw, !str.isEmpty else { return "" }
        return str
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    static func decodeHTMLEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var result = input
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&hellip;", with: "…")
            .replacingOccurrences(of: "&middot;", with: "·")

        // Numeric entities: &#1234; and &#x1F600;
        if result.contains("&#") {
            let regex = try? NSRegularExpression(pattern: #"&#(?:x([0-9a-fA-F]+)|(\d+));"#)
            if let regex {
                let ns = result as NSString
                let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
                for match in matches.reversed() {
                    let scalarValue: UInt32?
                    if match.range(at: 1).location != NSNotFound {
                        scalarValue = UInt32(ns.substring(with: match.range(at: 1)), radix: 16)
                    } else if match.range(at: 2).location != NSNotFound {
                        scalarValue = UInt32(ns.substring(with: match.range(at: 2)), radix: 10)
                    } else {
                        scalarValue = nil
                    }
                    if let val = scalarValue, let scalar = UnicodeScalar(val) {
                        let start = result.index(result.startIndex, offsetBy: match.range.location)
                        let end = result.index(start, offsetBy: match.range.length)
                        result.replaceSubrange(start..<end, with: String(scalar))
                    }
                }
            }
        }

        // Decode &amp; last so double-encoded entities don't over-decode in a single pass
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }

    /// RFC 3986 percent-encoding matching JS `encodeURIComponent` (encodes `+`, `/`, `=`, `&`, `?`, etc.).
    static func urlEncodeComponent(_ str: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return str.addingPercentEncoding(withAllowedCharacters: allowed) ?? str
    }

    /// `application/x-www-form-urlencoded` encoding (encodes `+`, `/`, `=`, `&`, `%`, etc.).
    static func formURLEncode(_ str: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return str.addingPercentEncoding(withAllowedCharacters: allowed) ?? str
    }

    /// Flexible JSON integer extractor handling `Int`, `Int64`, `Double`, or numeric `String`.
    static func int64Value(_ value: Any?) -> Int64 {
        if let v = value as? Int64 { return v }
        if let v = value as? Int { return Int64(v) }
        if let v = value as? Double { return Int64(v) }
        if let v = value as? NSNumber { return v.int64Value }
        if let s = value as? String, let parsed = Int64(s) { return parsed }
        return 0
    }

    static func intValue(_ value: Any?) -> Int {
        Int(int64Value(value))
    }

    static func stringValue(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }
}
