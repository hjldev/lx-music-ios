import Foundation
import CommonCrypto
import CryptoKit
import Security
import zlib

/// Native cryptography, hashing, and zlib/gzip compression primitives with zero third-party dependencies.
enum CryptoUtils {

    enum CryptoError: LocalizedError {
        case aesFailed(CCCryptorStatus)
        case rsaKeyInvalid
        case rsaEncryptFailed(String)
        case zlibFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .aesFailed(let status): return "AES operation failed (\(status))"
            case .rsaKeyInvalid: return "Invalid RSA public key"
            case .rsaEncryptFailed(let msg): return "RSA encryption failed: \(msg)"
            case .zlibFailed(let code): return "Zlib operation failed (\(code))"
            }
        }
    }

    // MARK: - Hashing

    static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    static func md5Hex(_ string: String) -> String {
        md5(Data(string.utf8)).hexLowercased
    }

    static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }

    static func randomBytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            for i in 0..<count {
                bytes[i] = UInt8.random(in: 0...255)
            }
        }
        return Data(bytes)
    }

    // MARK: - AES (CBC / ECB with PKCS#7 padding)

    static func aesEncrypt(data: Data, key: Data, iv: Data? = nil, isECB: Bool = false) throws -> Data {
        try aesCrypt(operation: CCOperation(kCCEncrypt), data: data, key: key, iv: iv, isECB: isECB)
    }

    static func aesDecrypt(data: Data, key: Data, iv: Data? = nil, isECB: Bool = false) throws -> Data {
        try aesCrypt(operation: CCOperation(kCCDecrypt), data: data, key: key, iv: iv, isECB: isECB)
    }

    private static func aesCrypt(operation: CCOperation, data: Data, key: Data, iv: Data?, isECB: Bool) throws -> Data {
        var options = CCOptions(kCCOptionPKCS7Padding)
        if isECB {
            options |= CCOptions(kCCOptionECBMode)
        }

        let outCapacity = data.count + kCCBlockSizeAES128
        var outBytes = [UInt8](repeating: 0, count: outCapacity)
        var numBytesProcessed: size_t = 0

        let status: CCCryptorStatus = data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                if let iv, !isECB {
                    return iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            &outBytes, outCapacity,
                            &numBytesProcessed
                        )
                    }
                } else {
                    return CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        options,
                        keyPtr.baseAddress, key.count,
                        nil,
                        dataPtr.baseAddress, data.count,
                        &outBytes, outCapacity,
                        &numBytesProcessed
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw CryptoError.aesFailed(status)
        }
        return Data(bytes: outBytes, count: numBytesProcessed)
    }

    // MARK: - RSA Raw (No Padding) Public Key Encryption

    /// Extracts DER bytes from a PEM-encoded public key (SPKI or PKCS#1), stripping SPKI header if present,
    /// and encrypts `plainData` with `RSA_NO_PADDING` (matching Node `crypto.publicEncrypt({ padding: RSA_NO_PADDING })`).
    static func rsaEncryptNoPadding(data: Data, publicKeyPEM: String) throws -> Data {
        let b64 = publicKeyPEM
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        guard let der = Data(base64Encoded: b64) else {
            throw CryptoError.rsaKeyInvalid
        }
        return try rsaEncryptNoPadding(data: data, publicKeyDER: der)
    }

    static func rsaEncryptNoPadding(data: Data, publicKeyDER: Data) throws -> Data {
        let keyData = stripSPKIHeaderIfNeeded(publicKeyDER)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var cfError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &cfError) else {
            // Try passing raw DER directly in case iOS accepts SPKI natively
            if let fallbackKey = SecKeyCreateWithData(publicKeyDER as CFData, attrs as CFDictionary, &cfError) {
                return try encryptWithSecKey(data: data, secKey: fallbackKey)
            }
            throw CryptoError.rsaKeyInvalid
        }
        return try encryptWithSecKey(data: data, secKey: secKey)
    }

    private static func encryptWithSecKey(data: Data, secKey: SecKey) throws -> Data {
        let blockSize = SecKeyGetBlockSize(secKey)
        var padded = data
        if padded.count < blockSize {
            padded = Data(repeating: 0, count: blockSize - padded.count) + padded
        } else if padded.count > blockSize {
            padded = padded.suffix(blockSize)
        }
        var cfError: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(secKey, .rsaEncryptionRaw, padded as CFData, &cfError) as Data? else {
            let msg = cfError?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw CryptoError.rsaEncryptFailed(msg)
        }
        return encrypted
    }

    /// Strips X.509 SubjectPublicKeyInfo wrapper to obtain PKCS#1 RSAPublicKey DER if present.
    private static func stripSPKIHeaderIfNeeded(_ der: Data) -> Data {
        // Look for RSA OID 1.2.840.113549.1.1.1: 06 09 2A 86 48 86 F7 0D 01 01 01
        let rsaOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        guard let oidRange = der.range(of: Data(rsaOID)) else {
            return der
        }
        // After OID + NULL (05 00), comes BIT STRING (03 <len> 00 <PKCS#1>)
        var idx = oidRange.upperBound
        let bytes = [UInt8](der)
        while idx < bytes.count && bytes[idx] != 0x03 {
            idx += 1
        }
        guard idx < bytes.count, bytes[idx] == 0x03 else { return der }
        idx += 1 // skip 0x03
        guard idx < bytes.count else { return der }
        if bytes[idx] & 0x80 != 0 {
            let lenBytes = Int(bytes[idx] & 0x7F)
            idx += 1 + lenBytes
        } else {
            idx += 1
        }
        if idx < bytes.count && bytes[idx] == 0x00 {
            idx += 1 // skip unused-bits byte
        }
        guard idx < bytes.count else { return der }
        return Data(bytes[idx...])
    }

    // MARK: - Zlib & Gzip

    /// Decompresses RFC 1950 zlib data. Supports `tolerateTruncated` (`Z_SYNC_FLUSH`) required by TX QRC lyrics.
    static func zlibInflate(_ data: Data, windowBits: Int32 = MAX_WBITS, tolerateTruncated: Bool = false) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw CryptoError.zlibFailed(initStatus)
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 16_384
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        let flushMode: Int32 = tolerateTruncated ? Z_SYNC_FLUSH : Z_NO_FLUSH

        var status: Int32 = Z_OK
        try data.withUnsafeBytes { rawBuf in
            guard let basePtr = rawBuf.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: basePtr)
            stream.avail_in = uInt(data.count)

            while true {
                let produced: Int = chunk.withUnsafeMutableBytes { outBuf in
                    stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = zlib.inflate(&stream, flushMode)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(chunk, count: produced)
                }
                if status == Z_STREAM_END {
                    break
                }
                if status == Z_OK {
                    if stream.avail_in == 0 && produced == 0 {
                        break
                    }
                    continue
                }
                if tolerateTruncated && status == Z_BUF_ERROR && !output.isEmpty {
                    break
                }
                throw CryptoError.zlibFailed(status)
            }
        }
        return output
    }

    /// Compresses data with RFC 1950 zlib (`windowBits = 15`) or RFC 1952 gzip (`windowBits = 15 + 16`).
    static func zlibDeflate(_ data: Data, windowBits: Int32 = MAX_WBITS) throws -> Data {
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            windowBits,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw CryptoError.zlibFailed(initStatus)
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 16_384
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        try data.withUnsafeBytes { rawBuf in
            stream.next_in = UnsafeMutablePointer(mutating: rawBuf.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)

            var status: Int32 = Z_OK
            repeat {
                let produced: Int = chunk.withUnsafeMutableBytes { outBuf in
                    stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = zlib.deflate(&stream, Z_FINISH)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(chunk, count: produced)
                }
                if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR {
                    throw CryptoError.zlibFailed(status)
                }
            } while status != Z_STREAM_END
        }
        return output
    }

    static func gzipCompress(_ data: Data) throws -> Data {
        try zlibDeflate(data, windowBits: MAX_WBITS + 16)
    }

    /// Auto-detects gzip or zlib stream (`windowBits = MAX_WBITS + 32`).
    static func gunzipDecompress(_ data: Data) throws -> Data {
        try zlibInflate(data, windowBits: MAX_WBITS + 32)
    }
}

// MARK: - Data Hex Helpers

extension Data {
    var hexLowercased: String {
        map { String(format: "%02x", $0) }.joined()
    }

    var hexUppercased: String {
        map { String(format: "%02X", $0) }.joined()
    }

    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self.init(bytes)
    }
}
