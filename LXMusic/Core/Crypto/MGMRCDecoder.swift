import Foundation

/// Exact 1:1 port of Migu MRC lyric decryption (`src/renderer/utils/musicSdk/mg/utils/mrc.js`).
/// Signed 64-bit XXTEA decryption using arithmetic right shifts, decoded as UTF-16LE.
enum MGMRCDecoder {
    private static let delta: Int64 = 2654435769 // 0x9E3779B9
    private static let minLength = 32

    private static let keyArr: [Int64] = [
        27303562373562475,
        18014862372307051,
        22799692160172081,
        34058940340699235,
        30962724186095721,
        27303523720101991,
        27303523720101998,
        31244139033526382,
        28992395054481524,
    ]

    static func decrypt(_ data: String) -> String {
        guard data.count >= minLength else { return data }
        var blocks = toInt64Array(data)
        guard !blocks.isEmpty else { return data }
        teaDecrypt(&blocks, key: keyArr)
        return int64ArrayToUTF16String(blocks)
    }

    private static func toInt64Array(_ hex: String) -> [Int64] {
        let count = hex.count / 16
        guard count > 0 else { return [] }
        var result: [Int64] = []
        result.reserveCapacity(count)
        var idx = hex.startIndex
        for _ in 0..<count {
            let next = hex.index(idx, offsetBy: 16)
            let chunk = hex[idx..<next]
            if let u = UInt64(chunk, radix: 16) {
                result.append(Int64(bitPattern: u))
            } else {
                result.append(0)
            }
            idx = next
        }
        return result
    }

    private static func teaDecrypt(_ data: inout [Int64], key: [Int64]) {
        let length = data.count
        guard length >= 1 else { return }

        var j2: Int64 = data[0]
        var j3: Int64 = (6 + (52 / Int64(length))) &* delta

        while j3 != 0 {
            let j4 = j3
            let j5 = 3 & (j4 >> 2) // arithmetic right shift on Int64
            var j6 = Int64(length)
            while true {
                j6 -= 1
                if j6 > 0 {
                    let j7 = data[Int(j6 - 1)]
                    let i = Int(j6)
                    let term1 = (j2 ^ j4) &+ (j7 ^ key[Int((3 & j6) ^ j5)])
                    let term2 = ((j7 >> 5) ^ (j2 &<< 2)) &+ ((j2 >> 3) ^ (j7 &<< 4))
                    j2 = data[i] &- (term1 ^ term2)
                    data[i] = j2
                } else {
                    break
                }
            }
            let j8 = data[length - 1]
            let term1 = (key[Int((j6 & 3) ^ j5)] ^ j8) &+ (j2 ^ j4)
            let term2 = ((j8 >> 5) ^ (j2 &<< 2)) &+ ((j2 >> 3) ^ (j8 &<< 4))
            j2 = data[0] &- (term1 ^ term2)
            data[0] = j2
            j3 = j4 &- delta
        }
    }

    private static func int64ArrayToUTF16String(_ data: [Int64]) -> String {
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(data.count * 4)
        for val in data {
            let u = UInt64(bitPattern: val)
            codeUnits.append(UInt16(u & 0xFFFF))
            codeUnits.append(UInt16((u >> 16) & 0xFFFF))
            codeUnits.append(UInt16((u >> 32) & 0xFFFF))
            codeUnits.append(UInt16((u >> 48) & 0xFFFF))
        }
        // Trim trailing NUL padding if present
        while codeUnits.last == 0 {
            codeUnits.removeLast()
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }
}
