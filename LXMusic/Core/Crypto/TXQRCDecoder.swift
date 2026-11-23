import Foundation

/// Exact 1:1 port of Tencent QQ Music QRC lyric decryption (`src/renderer/utils/musicSdk/tx/qrcDecode.js`).
/// NOTE: Uses Tencent's non-standard 3DES (modified S-boxes S2[23]=15 & S4[53]=10, 32-bit word byte-swaps,
/// and off-by-one PC-2 D-half shift `-27`) followed by `Z_SYNC_FLUSH` zlib decompression.
enum TXQRCDecoder {
    private static let desDecrypt = 0
    private static let desEncrypt = 1

    /// ASCII "!@#)(*$%123ZXC!@!@#)(NHL"
    private static let qrcKey: [UInt8] = [
        0x21, 0x40, 0x23, 0x29, 0x28, 0x2A, 0x24, 0x25,
        0x31, 0x32, 0x33, 0x5A, 0x58, 0x43, 0x21, 0x40,
        0x21, 0x40, 0x23, 0x29, 0x28, 0x4E, 0x48, 0x4C,
    ]

    private static let sbox: [[UInt32]] = [
        [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,
         0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,
         4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,
         15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
        [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,
         3,13,4,7,15,2,8,15,12,0,1,10,6,9,11,5, // index 23 = 15 (non-standard!)
         0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,
         13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
        [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,
         13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,
         13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,
         1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
        [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,
         13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,
         10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,
         3,15,0,6,10,10,13,8,9,4,5,11,12,7,2,14], // index 53 = 10 (non-standard!)
        [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,
         14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,
         4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,
         11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
        [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,
         10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,
         9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,
         4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
        [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,
         13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,
         1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,
         6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
        [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,
         1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,
         7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,
         2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11],
    ]

    private static let keyRndShift: [Int] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    private static let keyPermC: [Int] = [
        56,48,40,32,24,16,8,0,57,49,41,33,25,17,
        9,1,58,50,42,34,26,18,10,2,59,51,43,35,
    ]
    private static let keyPermD: [Int] = [
        62,54,46,38,30,22,14,6,61,53,45,37,29,21,
        13,5,60,52,44,36,28,20,12,4,27,19,11,3,
    ]
    private static let keyCompression: [Int] = [
        13,16,10,23,0,4,2,27,14,5,20,9,22,18,11,3,
        25,7,15,6,26,19,12,1,40,51,30,36,46,54,29,39,
        50,44,32,47,43,48,38,55,33,52,45,41,49,35,28,31,
    ]

    private static let ipS0Bits: [Int] = [
        57,49,41,33,25,17,9,1, 59,51,43,35,27,19,11,3,
        61,53,45,37,29,21,13,5, 63,55,47,39,31,23,15,7,
    ]
    private static let ipS1Bits: [Int] = [
        56,48,40,32,24,16,8,0, 58,50,42,34,26,18,10,2,
        60,52,44,36,28,20,12,4, 62,54,46,38,30,22,14,6,
    ]
    private static let pBoxBits: [Int] = [
        15,6,19,20,28,11,27,16, 0,14,22,25,4,17,30,9,
        1,7,23,13,31,26,2,8, 18,12,29,5,21,10,3,24,
    ]

    // Precomputed EDE3 decrypt schedules (constant across app lifetime)
    private static let schedules: [[[UInt8]]] = [
        keySchedule(Array(qrcKey[16..<24]), mode: desDecrypt),
        keySchedule(Array(qrcKey[8..<16]), mode: desEncrypt),
        keySchedule(Array(qrcKey[0..<8]), mode: desDecrypt),
    ]

    /// Decodes a hex-encoded QRC ciphertext string into UTF-8 lyric/XML text.
    static func decode(_ hexData: String) -> String {
        guard !hexData.isEmpty, let raw = Data(hexString: hexData), raw.count >= 8 else {
            return ""
        }
        var bytes = [UInt8](raw)
        let blockEnd = (bytes.count / 8) * 8

        var offset = 0
        while offset < blockEnd {
            var block = Array(bytes[offset..<(offset + 8)])
            block = desCrypt(block, schedule: schedules[0])
            block = desCrypt(block, schedule: schedules[1])
            block = desCrypt(block, schedule: schedules[2])
            for i in 0..<8 {
                bytes[offset + i] = block[i]
            }
            offset += 8
        }

        do {
            let inflated = try CryptoUtils.zlibInflate(Data(bytes), tolerateTruncated: true)
            return String(data: inflated, encoding: .utf8) ?? String(decoding: inflated, as: UTF8.self)
        } catch {
            return ""
        }
    }

    @inline(__always)
    private static func bitnum(_ a: [UInt8], _ b: Int, _ c: Int) -> UInt32 {
        let byteIdx = (b / 32) * 4 + 3 - ((b % 32) / 8)
        let bitShift = 7 - (b % 8)
        return ((UInt32(a[byteIdx]) >> bitShift) & 1) << c
    }

    @inline(__always)
    private static func bitnumIntR(_ a: UInt32, _ b: Int, _ c: Int) -> UInt32 {
        ((a >> (31 - b)) & 1) << c
    }

    @inline(__always)
    private static func bitnumIntL(_ a: UInt32, _ b: Int, _ c: Int) -> UInt32 {
        ((a << b) & 0x80000000) >> c
    }

    @inline(__always)
    private static func sboxBit(_ a: UInt32) -> Int {
        Int((a & 32) | ((a & 31) >> 1) | ((a & 1) << 4))
    }

    private static func initialPermutation(_ input: [UInt8]) -> (UInt32, UInt32) {
        var s0: UInt32 = 0
        var s1: UInt32 = 0
        for i in 0..<32 {
            s0 |= bitnum(input, ipS0Bits[i], 31 - i)
            s1 |= bitnum(input, ipS1Bits[i], 31 - i)
        }
        return (s0, s1)
    }

    private static func inversePermutation(_ s0: UInt32, _ s1: UInt32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 8)
        // out[3..0] for k = 0..3 (offsets 7-k, 15-k, 23-k, 31-k)
        for k in 0..<4 {
            let b0 = 7 - k
            let val =
                bitnumIntR(s1, b0, 7) | bitnumIntR(s0, b0, 6) |
                bitnumIntR(s1, b0 + 8, 5) | bitnumIntR(s0, b0 + 8, 4) |
                bitnumIntR(s1, b0 + 16, 3) | bitnumIntR(s0, b0 + 16, 2) |
                bitnumIntR(s1, b0 + 24, 1) | bitnumIntR(s0, b0 + 24, 0)
            out[3 - k] = UInt8(val & 0xFF)
        }
        // out[7..4] for k = 0..3 (offsets 3-k, 11-k, 19-k, 27-k)
        for k in 0..<4 {
            let b0 = 3 - k
            let val =
                bitnumIntR(s1, b0, 7) | bitnumIntR(s0, b0, 6) |
                bitnumIntR(s1, b0 + 8, 5) | bitnumIntR(s0, b0 + 8, 4) |
                bitnumIntR(s1, b0 + 16, 3) | bitnumIntR(s0, b0 + 16, 2) |
                bitnumIntR(s1, b0 + 24, 1) | bitnumIntR(s0, b0 + 24, 0)
            out[7 - k] = UInt8(val & 0xFF)
        }
        return out
    }

    private static func desF(_ state: UInt32, _ key: [UInt8]) -> UInt32 {
        let t1: UInt32 =
            bitnumIntL(state, 31, 0) | ((state & 0xF0000000) >> 1) |
            bitnumIntL(state, 4, 5) | bitnumIntL(state, 3, 6) |
            ((state & 0x0F000000) >> 3) | bitnumIntL(state, 8, 11) |
            bitnumIntL(state, 7, 12) | ((state & 0x00F00000) >> 5) |
            bitnumIntL(state, 12, 17) | bitnumIntL(state, 11, 18) |
            ((state & 0x000F0000) >> 7) | bitnumIntL(state, 16, 23)

        let t2: UInt32 =
            bitnumIntL(state, 15, 0) | ((state & 0x0000F000) << 15) |
            bitnumIntL(state, 20, 5) | bitnumIntL(state, 19, 6) |
            ((state & 0x00000F00) << 13) | bitnumIntL(state, 24, 11) |
            bitnumIntL(state, 23, 12) | ((state & 0x000000F0) << 11) |
            bitnumIntL(state, 28, 17) | bitnumIntL(state, 27, 18) |
            ((state & 0x0000000F) << 9) | bitnumIntL(state, 0, 23)

        let l0 = ((t1 >> 24) & 0xFF) ^ UInt32(key[0])
        let l1 = ((t1 >> 16) & 0xFF) ^ UInt32(key[1])
        let l2 = ((t1 >> 8) & 0xFF) ^ UInt32(key[2])
        let l3 = ((t2 >> 24) & 0xFF) ^ UInt32(key[3])
        let l4 = ((t2 >> 16) & 0xFF) ^ UInt32(key[4])
        let l5 = ((t2 >> 8) & 0xFF) ^ UInt32(key[5])

        let s: UInt32 =
            (sbox[0][sboxBit(l0 >> 2)] << 28) |
            (sbox[1][sboxBit(((l0 & 3) << 4) | (l1 >> 4))] << 24) |
            (sbox[2][sboxBit(((l1 & 0xF) << 2) | (l2 >> 6))] << 20) |
            (sbox[3][sboxBit(l2 & 0x3F)] << 16) |
            (sbox[4][sboxBit(l3 >> 2)] << 12) |
            (sbox[5][sboxBit(((l3 & 3) << 4) | (l4 >> 4))] << 8) |
            (sbox[6][sboxBit(((l4 & 0xF) << 2) | (l5 >> 6))] << 4) |
            sbox[7][sboxBit(l5 & 0x3F)]

        var out: UInt32 = 0
        for c in 0..<32 {
            out |= bitnumIntL(s, pBoxBits[c], c)
        }
        return out
    }

    private static func desCrypt(_ input: [UInt8], schedule: [[UInt8]]) -> [UInt8] {
        var (s0, s1) = initialPermutation(input)
        for i in 0..<15 {
            let prev = s1
            s1 = desF(s1, schedule[i]) ^ s0
            s0 = prev
        }
        s0 = desF(s1, schedule[15]) ^ s0
        return inversePermutation(s0, s1)
    }

    private static func keySchedule(_ key8: [UInt8], mode: Int) -> [[UInt8]] {
        var c: UInt32 = 0
        var d: UInt32 = 0
        for i in 0..<28 {
            c |= bitnum(key8, keyPermC[i], 31 - i)
            d |= bitnum(key8, keyPermD[i], 31 - i)
        }

        var schedule = Array(repeating: [UInt8](repeating: 0, count: 6), count: 16)
        for i in 0..<16 {
            let shift = keyRndShift[i]
            c = ((c << shift) | (c >> (28 - shift))) & 0xFFFFFFF0
            d = ((d << shift) | (d >> (28 - shift))) & 0xFFFFFFF0
            let togen = (mode == desDecrypt) ? (15 - i) : i
            for j in 0..<24 {
                schedule[togen][j / 8] |= UInt8(bitnumIntR(c, keyCompression[j], 7 - (j % 8)))
            }
            for j in 24..<48 {
                // Non-standard Tencent offset: `- 27` (standard DES uses `- 28`)
                schedule[togen][j / 8] |= UInt8(bitnumIntR(d, keyCompression[j] - 27, 7 - (j % 8)))
            }
        }
        return schedule
    }
}
