import Foundation

/// HTTP response container mirroring LX Music Desktop's `httpFetch` result.
struct HTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    var text: String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func jsonObject() throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    func jsonDictionary() throws -> [String: Any] {
        guard let dict = try jsonObject() as? [String: Any] else {
            throw HTTPClientError.invalidResponse("Expected JSON object")
        }
        return dict
    }

    func jsonArray() throws -> [Any] {
        guard let arr = try jsonObject() as? [Any] else {
            throw HTTPClientError.invalidResponse("Expected JSON array")
        }
        return arr
    }

    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower {
            return v
        }
        return nil
    }
}

enum HTTPClientError: LocalizedError {
    case invalidURL(String)
    case httpStatus(Int, String)
    case invalidResponse(String)
    case tooManyRequests
    case maxRetriesExceeded

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "无效的请求地址: \(url)"
        case .httpStatus(let code, let msg): return "HTTP \(code): \(msg)"
        case .invalidResponse(let msg): return msg
        case .tooManyRequests: return "服务器繁忙"
        case .maxRetriesExceeded: return "请求重试次数已达上限"
        }
    }
}

/// Delegate that suppresses automatic HTTP 3xx redirection so callers can inspect `Location`
/// (matching `needle`'s default `follow_max = 0` behavior used by KG/TX/WY/MG songlist shortlink parsers).
private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Async URLSession HTTP client replicating `src/renderer/utils/request.js`.
final class HTTPClient: @unchecked Sendable {
    static let shared = HTTPClient()

    static let defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36"
    static let defaultTimeout: TimeInterval = 15.0

    private let session: URLSession
    private let noRedirectSession: URLSession
    private let noRedirectDelegate = NoRedirectSessionDelegate()

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.defaultTimeout
        config.timeoutIntervalForResource = 60.0
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: config)

        let noRedirConfig = URLSessionConfiguration.default
        noRedirConfig.timeoutIntervalForRequest = Self.defaultTimeout
        noRedirConfig.httpShouldSetCookies = false
        noRedirConfig.httpCookieAcceptPolicy = .never
        self.noRedirectSession = URLSession(configuration: noRedirConfig, delegate: noRedirectDelegate, delegateQueue: nil)
    }

    enum BodyPayload {
        case none
        case raw(Data, contentType: String?)
        case json(Any)
        case jsonString(String)
        case form([String: String])
    }

    func request(
        _ urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: BodyPayload = .none,
        timeout: TimeInterval = HTTPClient.defaultTimeout,
        followRedirects: Bool = true
    ) async throws -> HTTPResponse {
        guard let url = URL(string: urlString) else {
            throw HTTPClientError.invalidURL(urlString)
        }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method.uppercased()

        var mergedHeaders: [String: String] = ["User-Agent": Self.defaultUserAgent]
        for (k, v) in headers {
            if k.lowercased() == "user-agent" {
                mergedHeaders.removeValue(forKey: "User-Agent")
            }
            mergedHeaders[k] = v
        }

        switch body {
        case .none:
            break
        case .raw(let data, let contentType):
            req.httpBody = data
            if let ct = contentType, !hasHeader(mergedHeaders, "content-type") {
                mergedHeaders["Content-Type"] = ct
            }
        case .json(let obj):
            req.httpBody = try JSONSerialization.data(withJSONObject: obj, options: [])
            if !hasHeader(mergedHeaders, "content-type") {
                mergedHeaders["Content-Type"] = "application/json; charset=utf-8"
            }
        case .jsonString(let jsonStr):
            req.httpBody = Data(jsonStr.utf8)
            if !hasHeader(mergedHeaders, "content-type") {
                mergedHeaders["Content-Type"] = "application/json; charset=utf-8"
            }
        case .form(let fields):
            let encoded = fields
                .map { "\(FormatUtils.formURLEncode($0.key))=\(FormatUtils.formURLEncode($0.value))" }
                .joined(separator: "&")
            req.httpBody = Data(encoded.utf8)
            if !hasHeader(mergedHeaders, "content-type") {
                mergedHeaders["Content-Type"] = "application/x-www-form-urlencoded"
            }
        }

        for (k, v) in mergedHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let activeSession = followRedirects ? session : noRedirectSession
        let (data, response) = try await activeSession.data(for: req)
        guard let httpResp = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse("Non-HTTP response")
        }

        var responseHeaders: [String: String] = [:]
        for (k, v) in httpResp.allHeaderFields {
            responseHeaders[String(describing: k).lowercased()] = String(describing: v)
        }

        return HTTPResponse(statusCode: httpResp.statusCode, headers: responseHeaders, data: data)
    }

    func get(
        _ urlString: String,
        headers: [String: String] = [:],
        timeout: TimeInterval = HTTPClient.defaultTimeout,
        followRedirects: Bool = true
    ) async throws -> HTTPResponse {
        try await request(urlString, method: "GET", headers: headers, body: .none, timeout: timeout, followRedirects: followRedirects)
    }

    func postJSON(
        _ urlString: String,
        json: Any,
        headers: [String: String] = [:],
        timeout: TimeInterval = HTTPClient.defaultTimeout
    ) async throws -> HTTPResponse {
        try await request(urlString, method: "POST", headers: headers, body: .json(json), timeout: timeout)
    }

    func postForm(
        _ urlString: String,
        form: [String: String],
        headers: [String: String] = [:],
        timeout: TimeInterval = HTTPClient.defaultTimeout
    ) async throws -> HTTPResponse {
        try await request(urlString, method: "POST", headers: headers, body: .form(form), timeout: timeout)
    }

    /// Retries an async operation up to `maxAttempts` times (matching LX Music's `retryNum` loops).
    static func withRetry<T>(maxAttempts: Int = 3, operation: () async throws -> T) async throws -> T {
        var lastError: Error = HTTPClientError.maxRetriesExceeded
        for attempt in 0..<max(1, maxAttempts) {
            do {
                return try await operation()
            } catch {
                lastError = error
                if Task.isCancelled { throw error }
                if attempt + 1 < maxAttempts {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
        }
        throw lastError
    }

    private func hasHeader(_ dict: [String: String], _ keyLowercased: String) -> Bool {
        dict.keys.contains { $0.lowercased() == keyLowercased }
    }
}
