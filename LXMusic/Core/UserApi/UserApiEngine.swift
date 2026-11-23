import Foundation
import JavaScriptCore

/// Native iOS `JavaScriptCore` execution engine implementing LX Music v2 `globalThis.lx` custom source protocol
/// (`src/main/modules/userApi/renderer/preload.js`).
/// Runs all JS execution on a dedicated serial queue to ensure thread safety and clean async bridging.
final class UserApiEngine: @unchecked Sendable {

    enum EngineError: LocalizedError {
        case notInitialized
        case scriptError(String)
        case unsupportedSource(MusicSource)
        case timeout
        case invalidURLResponse

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "自定义音源尚未初始化完成"
            case .scriptError(let msg): return "音源脚本错误: \(msg)"
            case .unsupportedSource(let s): return "当前音源不支持 \(s.displayName)"
            case .timeout: return "自定义音源响应超时 (20s)"
            case .invalidURLResponse: return "自定义音源返回了无效的播放链接"
            }
        }
    }

    private let jsQueue = DispatchQueue(label: "cn.toside.lxmusic.userapi.js", qos: .userInitiated)
    private var context: JSContext?
    private var activeScript: UserApiScript?
    private var activeTasks: [String: URLSessionDataTask] = [:]
    private var activeTimers: [Int: DispatchWorkItem] = [:]
    private var nextTimerId = 1
    private var didReceiveInit = false
    private var didShowUpdateAlert = false
    private var capabilities: [MusicSource: UserApiSourceCapability] = [:]

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    var onStatusChange: ((UserApiRuntimeStatus) -> Void)?
    var onUpdateAlert: ((UserApiUpdateAlert) -> Void)?

    // MARK: - Lifecycle

    func unload() {
        jsQueue.async { [weak self] in
            self?.teardownLocked()
            self?.notifyStatus(.idle)
        }
    }

    func load(script: UserApiScript) {
        jsQueue.async { [weak self] in
            guard let self else { return }
            self.teardownLocked()
            self.activeScript = script
            self.notifyStatus(UserApiRuntimeStatus(isInitialized: false, isInitializing: true, message: "正在初始化音源...", sources: [:]))

            let ctx = JSContext()!
            self.context = ctx
            ctx.exceptionHandler = { [weak self] _, exception in
                guard let self else { return }
                let msg = exception?.toString() ?? "Unknown JS error"
                if !self.didReceiveInit {
                    self.didReceiveInit = true
                    self.notifyStatus(UserApiRuntimeStatus(isInitialized: false, isInitializing: false, message: msg, sources: [:]))
                }
            }

            self.injectNativeBridges(into: ctx, script: script)
            ctx.evaluateScript(Self.bootstrapJS)
            ctx.evaluateScript(script.script)

            // Guard against scripts that never call `lx.send('inited', ...)`
            let scriptId = script.id
            self.jsQueue.asyncAfter(deadline: .now() + 15.0) { [weak self] in
                guard let self, self.activeScript?.id == scriptId, !self.didReceiveInit else { return }
                self.didReceiveInit = true
                self.notifyStatus(UserApiRuntimeStatus(
                    isInitialized: false,
                    isInitializing: false,
                    message: "初始化超时（脚本未调用 lx.send('inited')）",
                    sources: [:]
                ))
            }
        }
    }

    private func teardownLocked() {
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        for (_, timer) in activeTimers { timer.cancel() }
        activeTimers.removeAll()
        context = nil
        activeScript = nil
        didReceiveInit = false
        didShowUpdateAlert = false
        capabilities = [:]
    }

    private func notifyStatus(_ status: UserApiRuntimeStatus) {
        let cb = onStatusChange
        DispatchQueue.main.async {
            cb?(status)
        }
    }

    // MARK: - Public Request API

    func requestMusicUrl(source: MusicSource, quality: AudioQuality, musicInfo: MusicInfo) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            final class OnceResolver: @unchecked Sendable {
                private let lock = NSLock()
                private var finished = false
                private let continuation: CheckedContinuation<String, Error>
                init(_ continuation: CheckedContinuation<String, Error>) {
                    self.continuation = continuation
                }
                func finish(_ result: Result<String, Error>) {
                    lock.lock()
                    guard !finished else {
                        lock.unlock()
                        return
                    }
                    finished = true
                    lock.unlock()
                    continuation.resume(with: result)
                }
            }

            let resolver = OnceResolver(continuation)

            // 20-second timeout matching `src/main/modules/userApi/main.ts`
            jsQueue.asyncAfter(deadline: .now() + 20.0) {
                resolver.finish(.failure(EngineError.timeout))
            }

            jsQueue.async { [weak self] in
                guard let self, let ctx = self.context, self.didReceiveInit else {
                    resolver.finish(.failure(EngineError.notInitialized))
                    return
                }
                guard let cap = self.capabilities[source], cap.actions.contains(.musicUrl) else {
                    resolver.finish(.failure(EngineError.unsupportedSource(source)))
                    return
                }

                let legacyDict = musicInfo.toLegacyDictionary()
                let reqKey = UUID().uuidString

                let resolveBlock: @convention(block) (JSValue) -> Void = { val in
                    let urlStr = val.toString() ?? ""
                    if urlStr.count <= 2048 && (urlStr.hasPrefix("http://") || urlStr.hasPrefix("https://")) {
                        resolver.finish(.success(urlStr))
                    } else {
                        resolver.finish(.failure(EngineError.invalidURLResponse))
                    }
                }
                let rejectBlock: @convention(block) (JSValue) -> Void = { errVal in
                    let msg = errVal.toString() ?? "Request failed"
                    if msg.contains("服务器繁忙") || msg.lowercased().contains("too many requests") {
                        resolver.finish(.failure(HTTPClientError.tooManyRequests))
                    } else {
                        resolver.finish(.failure(EngineError.scriptError(msg)))
                    }
                }

                guard let invokeFn = ctx.objectForKeyedSubscript("__lxInvokeRequest") else {
                    resolver.finish(.failure(EngineError.notInitialized))
                    return
                }

                let payload: [String: Any] = [
                    "source": source.rawValue,
                    "action": "musicUrl",
                    "info": [
                        "type": quality.rawValue,
                        "musicInfo": legacyDict,
                    ],
                ]
                invokeFn.call(withArguments: [
                    reqKey,
                    payload,
                    unsafeBitCast(resolveBlock, to: AnyObject.self),
                    unsafeBitCast(rejectBlock, to: AnyObject.self),
                ])
            }
        }
    }

    // MARK: - Native Bridges into JSContext

    private func injectNativeBridges(into ctx: JSContext, script: UserApiScript) {
        // 1. Timers (`setTimeout` / `clearTimeout`)
        let setTimeoutBlock: @convention(block) (JSValue, JSValue) -> Int = { [weak self] callback, delayVal in
            guard let self else { return 0 }
            let delayMs = max(0, delayVal.isNumber ? delayVal.toDouble() : 0)
            let timerId = self.nextTimerId
            self.nextTimerId += 1
            let managed = JSManagedValue(value: callback)
            ctx.virtualMachine.addManagedReference(managed, withOwner: self)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.activeTimers.removeValue(forKey: timerId)
                if let fn = managed?.value {
                    fn.call(withArguments: [])
                }
                if let managed {
                    ctx.virtualMachine.removeManagedReference(managed, withOwner: self)
                }
            }
            self.activeTimers[timerId] = work
            self.jsQueue.asyncAfter(deadline: .now() + delayMs / 1000.0, execute: work)
            return timerId
        }
        let clearTimeoutBlock: @convention(block) (Int) -> Void = { [weak self] timerId in
            self?.activeTimers.removeValue(forKey: timerId)?.cancel()
        }
        ctx.setObject(unsafeBitCast(setTimeoutBlock, to: AnyObject.self), forKeyedSubscript: "setTimeout" as NSString)
        ctx.setObject(unsafeBitCast(clearTimeoutBlock, to: AnyObject.self), forKeyedSubscript: "clearTimeout" as NSString)

        // 2. Script metadata
        let scriptInfo: [String: Any] = [
            "name": script.name,
            "description": script.description,
            "version": script.version,
            "author": script.author,
            "homepage": script.homepage,
            "rawScript": script.script,
        ]
        ctx.setObject(scriptInfo, forKeyedSubscript: "__lxCurrentScriptInfo" as NSString)

        // 3. `lx.send('inited', ...)` & `lx.send('updateAlert', ...)`
        let handleInitedBlock: @convention(block) (JSValue) -> String = { [weak self] infoVal in
            guard let self else { return "Engine released" }
            if self.didReceiveInit { return "Script is inited" }
            self.didReceiveInit = true

            guard let dict = infoVal.toDictionary() as? [String: Any],
                  let rawSources = dict["sources"] as? [String: Any] else {
                let err = "Missing required parameter init info"
                self.notifyStatus(UserApiRuntimeStatus(isInitialized: false, isInitializing: false, message: err, sources: [:]))
                return err
            }

            let allowedOnlineQualities: Set<AudioQuality> = [.k128, .k320, .flac, .flac24bit]
            var parsedSources: [MusicSource: UserApiSourceCapability] = [:]

            for source in MusicSource.allCases {
                guard let userSrc = rawSources[source.rawValue] as? [String: Any],
                      (userSrc["type"] as? String) == "music" else { continue }

                let rawActions = (userSrc["actions"] as? [String]) ?? []
                let allowedActions: [UserApiAction] = (source == .local) ? [.musicUrl, .lyric, .pic] : [.musicUrl]
                let actions = allowedActions.filter { rawActions.contains($0.rawValue) }

                let rawQualities = (userSrc["qualitys"] as? [String]) ?? []
                let qualities: [AudioQuality] = (source == .local)
                    ? []
                    : rawQualities.compactMap { AudioQuality.fromRawMigrated($0) }.filter { allowedOnlineQualities.contains($0) }

                parsedSources[source] = UserApiSourceCapability(type: "music", actions: actions, qualitys: qualities)
            }

            self.capabilities = parsedSources
            self.notifyStatus(UserApiRuntimeStatus(
                isInitialized: true,
                isInitializing: false,
                message: nil,
                sources: parsedSources
            ))
            return ""
        }
        ctx.setObject(unsafeBitCast(handleInitedBlock, to: AnyObject.self), forKeyedSubscript: "__lxNativeInit" as NSString)

        let handleUpdateAlertBlock: @convention(block) (JSValue) -> String = { [weak self] dataVal in
            guard let self else { return "" }
            if self.didShowUpdateAlert { return "The update alert can only be called once." }
            self.didShowUpdateAlert = true
            guard let dict = dataVal.toDictionary() as? [String: Any],
                  let rawLog = dict["log"] as? String, !rawLog.isEmpty else {
                return "log is required."
            }
            let log = rawLog.count > 1024 ? String(rawLog.prefix(1024)) + "..." : rawLog
            var updateUrl = dict["updateUrl"] as? String
            if let u = updateUrl, (!u.hasPrefix("http://") && !u.hasPrefix("https://")) || u.count > 1024 {
                updateUrl = nil
            }
            if self.activeScript?.allowShowUpdateAlert == true {
                let alert = UserApiUpdateAlert(scriptName: self.activeScript?.name ?? "自定义音源", log: log, updateUrl: updateUrl)
                let cb = self.onUpdateAlert
                DispatchQueue.main.async { cb?(alert) }
            }
            return ""
        }
        ctx.setObject(unsafeBitCast(handleUpdateAlertBlock, to: AnyObject.self), forKeyedSubscript: "__lxNativeUpdateAlert" as NSString)

        // 4. HTTP request bridge (`lx.request`)
        let httpRequestBlock: @convention(block) (String, JSValue, JSValue) -> String = { [weak self] urlStr, optsVal, callbackVal in
            guard let self else { return "" }
            let taskId = UUID().uuidString
            let managedCallback = JSManagedValue(value: callbackVal)
            ctx.virtualMachine.addManagedReference(managedCallback, withOwner: self)

            func invokeCallback(errorMessage: String?, respDict: [String: Any]?, bodyVal: Any?) {
                self.jsQueue.async { [weak self] in
                    guard let self else { return }
                    self.activeTasks.removeValue(forKey: taskId)
                    defer {
                        if let managedCallback {
                            ctx.virtualMachine.removeManagedReference(managedCallback, withOwner: self)
                        }
                    }
                    guard let cb = managedCallback?.value else { return }
                    if let err = errorMessage {
                        let jsErr = ctx.evaluateScript("new Error(\(Self.jsStringLiteral(err)))")!
                        cb.call(withArguments: [jsErr, NSNull(), NSNull()])
                    } else {
                        cb.call(withArguments: [NSNull(), respDict ?? NSNull(), bodyVal ?? NSNull()])
                    }
                }
            }

            guard let url = URL(string: urlStr) else {
                invokeCallback(errorMessage: "Invalid URL: \(urlStr)", respDict: nil, bodyVal: nil)
                return taskId
            }

            let opts = (optsVal.toDictionary() as? [String: Any]) ?? [:]
            let method = ((opts["method"] as? String) ?? "GET").uppercased()
            let timeoutMs = (opts["timeout"] as? Double) ?? 60_000
            let timeoutSec = min(max(timeoutMs / 1000.0, 1.0), 60.0)

            var request = URLRequest(url: url, timeoutInterval: timeoutSec)
            request.httpMethod = method

            var hasContentType = false
            if let headers = opts["headers"] as? [String: Any] {
                for (k, v) in headers {
                    if k.lowercased() == "content-type" { hasContentType = true }
                    request.setValue(String(describing: v), forHTTPHeaderField: k)
                }
            }

            if let bodyObj = opts["body"] {
                if let str = bodyObj as? String {
                    request.httpBody = Data(str.utf8)
                } else if JSONSerialization.isValidJSONObject(bodyObj),
                          let data = try? JSONSerialization.data(withJSONObject: bodyObj) {
                    request.httpBody = data
                    if !hasContentType {
                        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                    }
                }
            } else if let form = opts["form"] as? [String: Any] {
                let encoded = form.map { k, v in
                    "\(FormatUtils.formURLEncode(k))=\(FormatUtils.formURLEncode(String(describing: v)))"
                }.joined(separator: "&")
                request.httpBody = Data(encoded.utf8)
                if !hasContentType {
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                }
            } else if let formData = opts["formData"] as? [String: Any] {
                let boundary = "----LXMusicBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                var payload = Data()
                for (k, v) in formData {
                    payload.append(Data("--\(boundary)\r\n".utf8))
                    payload.append(Data("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".utf8))
                    payload.append(Data("\(String(describing: v))\r\n".utf8))
                }
                payload.append(Data("--\(boundary)--\r\n".utf8))
                request.httpBody = payload
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            }

            let task = self.session.dataTask(with: request) { data, response, error in
                if let error {
                    invokeCallback(errorMessage: error.localizedDescription, respDict: nil, bodyVal: nil)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    invokeCallback(errorMessage: "No HTTP response", respDict: nil, bodyVal: nil)
                    return
                }
                let rawData = data ?? Data()
                let rawText = String(data: rawData, encoding: .utf8) ?? String(decoding: rawData, as: UTF8.self)
                let parsedBody: Any
                if let json = try? JSONSerialization.jsonObject(with: rawData, options: [.fragmentsAllowed]) {
                    parsedBody = json
                } else {
                    parsedBody = rawText
                }
                var headersMap: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    headersMap[String(describing: k).lowercased()] = String(describing: v)
                }
                let respObj: [String: Any] = [
                    "statusCode": http.statusCode,
                    "statusMessage": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                    "headers": headersMap,
                    "bytes": rawData.count,
                    "raw": rawData.base64EncodedString(),
                    "body": parsedBody,
                ]
                invokeCallback(errorMessage: nil, respDict: respObj, bodyVal: parsedBody)
            }
            self.activeTasks[taskId] = task
            task.resume()
            return taskId
        }
        ctx.setObject(unsafeBitCast(httpRequestBlock, to: AnyObject.self), forKeyedSubscript: "__lxNativeRequest" as NSString)

        let cancelRequestBlock: @convention(block) (String) -> Void = { [weak self] taskId in
            self?.activeTasks.removeValue(forKey: taskId)?.cancel()
        }
        ctx.setObject(unsafeBitCast(cancelRequestBlock, to: AnyObject.self), forKeyedSubscript: "__lxNativeCancelRequest" as NSString)

        // 5. Crypto & Zlib native bridges (base64 I/O across JSC boundary)
        let md5Block: @convention(block) (String) -> String = { str in
            CryptoUtils.md5Hex(str)
        }
        let randomBytesBlock: @convention(block) (Int) -> String = { size in
            CryptoUtils.randomBytes(max(0, min(size, 65536))).base64EncodedString()
        }
        let aesEncryptBlock: @convention(block) (String, String, String, String) -> String = { dataB64, mode, keyB64, ivB64 in
            guard let data = Data(base64Encoded: dataB64),
                  let key = Data(base64Encoded: keyB64) else { return "" }
            let isECB = mode.lowercased().contains("ecb")
            let iv = ivB64.isEmpty ? nil : Data(base64Encoded: ivB64)
            let out = (try? CryptoUtils.aesEncrypt(data: data, key: key, iv: iv, isECB: isECB)) ?? Data()
            return out.base64EncodedString()
        }
        let rsaEncryptBlock: @convention(block) (String, String) -> String = { dataB64, keyStr in
            guard let data = Data(base64Encoded: dataB64) else { return "" }
            let out = (try? CryptoUtils.rsaEncryptNoPadding(data: data, publicKeyPEM: keyStr)) ?? Data()
            return out.base64EncodedString()
        }
        let inflateBlock: @convention(block) (String) -> String = { b64 in
            guard let data = Data(base64Encoded: b64),
                  let out = try? CryptoUtils.zlibInflate(data) else { return "" }
            return out.base64EncodedString()
        }
        let deflateBlock: @convention(block) (String) -> String = { b64 in
            guard let data = Data(base64Encoded: b64),
                  let out = try? CryptoUtils.zlibDeflate(data) else { return "" }
            return out.base64EncodedString()
        }

        ctx.setObject(unsafeBitCast(md5Block, to: AnyObject.self), forKeyedSubscript: "__lxNativeMD5" as NSString)
        ctx.setObject(unsafeBitCast(randomBytesBlock, to: AnyObject.self), forKeyedSubscript: "__lxNativeRandomBytes" as NSString)
        ctx.setObject(unsafeBitCast(aesEncryptBlock, to: AnyObject.self), forKeyedSubscript: "__lxNativeAESEncrypt" as NSString)
        ctx.setObject(unsafeBitCast(rsaEncryptBlock, to: AnyObject.self), forKeyedSubscript: "__lxNativeRSAEncrypt" as NSString)
        ctx.setObject(unsafeBitCast(inflateBlock, to: AnyObject.self), forKeyedSubscript: "__lxNativeInflate" as NSString)
        ctx.setObject(unsafeBitCast(deflateBlock, to: AnyObject.self), forKeyedSubscript: "__lxNativeDeflate" as NSString)
    }

    private static func jsStringLiteral(_ str: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [str]),
           let json = String(data: data, encoding: .utf8), json.count >= 2 {
            return String(json.dropFirst().dropLast())
        }
        return "\"Error\""
    }

    // MARK: - JavaScript Runtime Bootstrap (globalThis.lx + Buffer + Base64 + console)

    private static let bootstrapJS = #"""
    (function () {
      const g = globalThis;
      if (!g.window) g.window = g;
      if (!g.console) {
        g.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
      }

      const b64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      const b64Lookup = new Uint8Array(256);
      for (let i = 0; i < b64Chars.length; i++) b64Lookup[b64Chars.charCodeAt(i)] = i;

      function bytesToBase64(bytes) {
        let out = '';
        const len = bytes.length;
        for (let i = 0; i < len; i += 3) {
          const b0 = bytes[i];
          const b1 = i + 1 < len ? bytes[i + 1] : 0;
          const b2 = i + 2 < len ? bytes[i + 2] : 0;
          out += b64Chars[b0 >> 2];
          out += b64Chars[((b0 & 3) << 4) | (b1 >> 4)];
          out += i + 1 < len ? b64Chars[((b1 & 15) << 2) | (b2 >> 6)] : '=';
          out += i + 2 < len ? b64Chars[b2 & 63] : '=';
        }
        return out;
      }

      function base64ToBytes(str) {
        str = String(str).replace(/[^A-Za-z0-9+/=]/g, '');
        let pad = 0;
        if (str.endsWith('==')) pad = 2;
        else if (str.endsWith('=')) pad = 1;
        const len = (str.length * 3) / 4 - pad;
        const out = new Uint8Array(Math.max(0, len | 0));
        let p = 0;
        for (let i = 0; i < str.length; i += 4) {
          const e1 = b64Lookup[str.charCodeAt(i)];
          const e2 = b64Lookup[str.charCodeAt(i + 1)];
          const e3 = b64Lookup[str.charCodeAt(i + 2)];
          const e4 = b64Lookup[str.charCodeAt(i + 3)];
          if (p < out.length) out[p++] = (e1 << 2) | (e2 >> 4);
          if (p < out.length) out[p++] = ((e2 & 15) << 4) | (e3 >> 2);
          if (p < out.length) out[p++] = ((e3 & 3) << 6) | e4;
        }
        return out;
      }

      function utf8ToBytes(str) {
        const out = [];
        for (let i = 0; i < str.length; i++) {
          let c = str.charCodeAt(i);
          if (c < 0x80) { out.push(c); }
          else if (c < 0x800) { out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
          else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
            const c2 = str.charCodeAt(++i);
            const cp = 0x10000 + (((c & 0x3ff) << 10) | (c2 & 0x3ff));
            out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
          } else {
            out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
          }
        }
        return new Uint8Array(out);
      }

      function bytesToUtf8(bytes) {
        let out = '';
        let i = 0;
        while (i < bytes.length) {
          const b0 = bytes[i++];
          if (b0 < 0x80) { out += String.fromCharCode(b0); }
          else if (b0 < 0xe0) {
            const b1 = bytes[i++] & 0x3f;
            out += String.fromCharCode(((b0 & 0x1f) << 6) | b1);
          } else if (b0 < 0xf0) {
            const b1 = bytes[i++] & 0x3f;
            const b2 = bytes[i++] & 0x3f;
            out += String.fromCharCode(((b0 & 0x0f) << 12) | (b1 << 6) | b2);
          } else {
            const b1 = bytes[i++] & 0x3f;
            const b2 = bytes[i++] & 0x3f;
            const b3 = bytes[i++] & 0x3f;
            let cp = ((b0 & 0x07) << 18) | (b1 << 12) | (b2 << 6) | b3;
            cp -= 0x10000;
            out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
          }
        }
        return out;
      }

      function bytesToHex(bytes) {
        let out = '';
        for (let i = 0; i < bytes.length; i++) out += bytes[i].toString(16).padStart(2, '0');
        return out;
      }

      function hexToBytes(hex) {
        const clean = String(hex).replace(/[^0-9a-fA-F]/g, '');
        const out = new Uint8Array(Math.floor(clean.length / 2));
        for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.substr(i * 2, 2), 16);
        return out;
      }

      function latin1ToBytes(str) {
        const out = new Uint8Array(str.length);
        for (let i = 0; i < str.length; i++) out[i] = str.charCodeAt(i) & 0xff;
        return out;
      }

      function bytesToLatin1(bytes) {
        let out = '';
        for (let i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
        return out;
      }

      class LXBuffer extends Uint8Array {
        toString(encoding = 'utf8') {
          const enc = String(encoding).toLowerCase();
          if (enc === 'hex') return bytesToHex(this);
          if (enc === 'base64') return bytesToBase64(this);
          if (enc === 'latin1' || enc === 'binary' || enc === 'ascii') return bytesToLatin1(this);
          return bytesToUtf8(this);
        }
        static from(input, encoding = 'utf8') {
          if (input instanceof Uint8Array) return new LXBuffer(input);
          if (Array.isArray(input)) return new LXBuffer(input);
          if (typeof input === 'string') {
            const enc = String(encoding).toLowerCase();
            if (enc === 'base64') return new LXBuffer(base64ToBytes(input));
            if (enc === 'hex') return new LXBuffer(hexToBytes(input));
            if (enc === 'latin1' || enc === 'binary' || enc === 'ascii') return new LXBuffer(latin1ToBytes(input));
            return new LXBuffer(utf8ToBytes(input));
          }
          return new LXBuffer(0);
        }
        static alloc(size, fill = 0) {
          const b = new LXBuffer(size);
          if (fill) b.fill(fill);
          return b;
        }
        static concat(list) {
          const total = list.reduce((s, b) => s + b.length, 0);
          const out = new LXBuffer(total);
          let offset = 0;
          for (const b of list) { out.set(b, offset); offset += b.length; }
          return out;
        }
        static isBuffer(obj) {
          return obj instanceof LXBuffer || obj instanceof Uint8Array;
        }
      }

      g.Buffer = LXBuffer;
      if (!g.btoa) g.btoa = (s) => bytesToBase64(latin1ToBytes(String(s)));
      if (!g.atob) g.atob = (s) => bytesToLatin1(base64ToBytes(String(s)));

      function toBase64Input(val) {
        if (val == null) return '';
        if (typeof val === 'string') return bytesToBase64(utf8ToBytes(val));
        if (val instanceof Uint8Array) return bytesToBase64(val);
        return bytesToBase64(LXBuffer.from(val));
      }

      const EVENT_NAMES = {
        request: 'request',
        inited: 'inited',
        updateAlert: 'updateAlert',
      };
      const eventNames = Object.values(EVENT_NAMES);
      const events = { request: null };

      g.__lxInvokeRequest = function (requestKey, data, resolve, reject) {
        if (typeof events.request !== 'function') {
          reject('Request event is not defined');
          return;
        }
        try {
          Promise.resolve(events.request({
            source: data.source,
            action: data.action,
            info: data.info,
          })).then(
            (res) => resolve(res),
            (err) => reject(err && err.message ? err.message : String(err))
          );
        } catch (err) {
          reject(err && err.message ? err.message : String(err));
        }
      };

      g.lx = {
        EVENT_NAMES,
        version: '2.0.0',
        env: 'mobile',
        currentScriptInfo: g.__lxCurrentScriptInfo || {},
        request(url, options, callback) {
          if (typeof options === 'function') {
            callback = options;
            options = {};
          }
          const taskId = g.__lxNativeRequest(String(url), options || {}, (err, resp, body) => {
            if (resp && typeof resp.raw === 'string') {
              resp.raw = LXBuffer.from(resp.raw, 'base64');
            }
            if (typeof callback === 'function') {
              callback(err, resp, body);
            }
          });
          return () => g.__lxNativeCancelRequest(taskId);
        },
        send(eventName, data) {
          return new Promise((resolve, reject) => {
            if (!eventNames.includes(eventName)) {
              return reject(new Error('The event is not supported: ' + eventName));
            }
            if (eventName === EVENT_NAMES.inited) {
              const err = g.__lxNativeInit(data);
              if (err) reject(new Error(err));
              else resolve();
            } else if (eventName === EVENT_NAMES.updateAlert) {
              const err = g.__lxNativeUpdateAlert(data);
              if (err) reject(new Error(err));
              else resolve();
            } else {
              reject(new Error('Unknown event name: ' + eventName));
            }
          });
        },
        on(eventName, handler) {
          if (!eventNames.includes(eventName)) {
            return Promise.reject(new Error('The event is not supported: ' + eventName));
          }
          if (eventName === EVENT_NAMES.request) {
            events.request = handler;
            return Promise.resolve();
          }
          return Promise.reject(new Error('The event is not supported: ' + eventName));
        },
        utils: {
          crypto: {
            aesEncrypt(buffer, mode, key, iv) {
              const b64 = g.__lxNativeAESEncrypt(toBase64Input(buffer), String(mode || 'aes-128-cbc'), toBase64Input(key), toBase64Input(iv));
              return LXBuffer.from(b64, 'base64');
            },
            rsaEncrypt(buffer, key) {
              const b64 = g.__lxNativeRSAEncrypt(toBase64Input(buffer), String(key || ''));
              return LXBuffer.from(b64, 'base64');
            },
            randomBytes(size) {
              const b64 = g.__lxNativeRandomBytes(Number(size) || 0);
              return LXBuffer.from(b64, 'base64');
            },
            md5(str) {
              return g.__lxNativeMD5(String(str));
            },
          },
          buffer: {
            from(...args) {
              return LXBuffer.from(...args);
            },
            bufToString(buf, format) {
              if (buf instanceof LXBuffer) return buf.toString(format || 'utf8');
              if (buf instanceof Uint8Array) return new LXBuffer(buf).toString(format || 'utf8');
              return LXBuffer.from(String(buf), 'binary').toString(format || 'utf8');
            },
          },
          zlib: {
            inflate(buf) {
              const b64 = g.__lxNativeInflate(toBase64Input(buf));
              if (!b64) return Promise.reject(new Error('zlib inflate failed'));
              return Promise.resolve(LXBuffer.from(b64, 'base64'));
            },
            deflate(data) {
              const b64 = g.__lxNativeDeflate(toBase64Input(data));
              if (!b64) return Promise.reject(new Error('zlib deflate failed'));
              return Promise.resolve(LXBuffer.from(b64, 'base64'));
            },
          },
        },
      };
    })();
    """#
}
