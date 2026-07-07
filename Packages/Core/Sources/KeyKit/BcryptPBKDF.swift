import Crypto
import Foundation

struct Blowfish {
    private var p = BlowfishTables.p
    private var s = BlowfishTables.s

    private func f(_ x: UInt32) -> UInt32 {
        let a = Int((x >> 24) & 0xff)
        let b = Int((x >> 16) & 0xff)
        let c = Int((x >> 8) & 0xff)
        let d = Int(x & 0xff)
        return ((s[a] &+ s[256 + b]) ^ s[512 + c]) &+ s[768 + d]
    }

    mutating func encipher(_ xl: inout UInt32, _ xr: inout UInt32) {
        var l = xl ^ p[0]
        var r = xr
        for i in stride(from: 1, through: 15, by: 2) {
            r ^= f(l) ^ p[i]
            l ^= f(r) ^ p[i + 1]
        }
        xl = r ^ p[17]
        xr = l
    }

    static func stream2word(_ data: [UInt8], _ j: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            word = (word << 8) | UInt32(data[j])
            j = (j + 1) % data.count
        }
        return word
    }

    mutating func expandstate(data: [UInt8], key: [UInt8]) {
        var j = 0
        for i in 0..<18 {
            p[i] ^= Self.stream2word(key, &j)
        }
        j = 0
        var dl: UInt32 = 0
        var dr: UInt32 = 0
        for i in stride(from: 0, to: 18, by: 2) {
            dl ^= Self.stream2word(data, &j)
            dr ^= Self.stream2word(data, &j)
            encipher(&dl, &dr)
            p[i] = dl
            p[i + 1] = dr
        }
        for i in stride(from: 0, to: 1024, by: 2) {
            dl ^= Self.stream2word(data, &j)
            dr ^= Self.stream2word(data, &j)
            encipher(&dl, &dr)
            s[i] = dl
            s[i + 1] = dr
        }
    }

    mutating func expand0state(key: [UInt8]) {
        var j = 0
        for i in 0..<18 {
            p[i] ^= Self.stream2word(key, &j)
        }
        var dl: UInt32 = 0
        var dr: UInt32 = 0
        for i in stride(from: 0, to: 18, by: 2) {
            encipher(&dl, &dr)
            p[i] = dl
            p[i + 1] = dr
        }
        for i in stride(from: 0, to: 1024, by: 2) {
            encipher(&dl, &dr)
            s[i] = dl
            s[i + 1] = dr
        }
    }
}

enum BcryptPBKDF {
    private static let magic = [UInt8]("OxychromaticBlowfishSwatDynamite".utf8)

    static func hash(sha2pass: [UInt8], sha2salt: [UInt8]) -> [UInt8] {
        var blowfish = Blowfish()
        blowfish.expandstate(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            blowfish.expand0state(key: sha2salt)
            blowfish.expand0state(key: sha2pass)
        }
        var j = 0
        var cdata = (0..<8).map { _ in Blowfish.stream2word(magic, &j) }
        for _ in 0..<64 {
            for block in stride(from: 0, to: 8, by: 2) {
                var left = cdata[block]
                var right = cdata[block + 1]
                blowfish.encipher(&left, &right)
                cdata[block] = left
                cdata[block + 1] = right
            }
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            out[4 * i + 0] = UInt8(cdata[i] & 0xff)
            out[4 * i + 1] = UInt8((cdata[i] >> 8) & 0xff)
            out[4 * i + 2] = UInt8((cdata[i] >> 16) & 0xff)
            out[4 * i + 3] = UInt8((cdata[i] >> 24) & 0xff)
        }
        return out
    }

    static func derive(passphrase: Data, salt: Data, rounds: Int, keyLength: Int) -> Data {
        precondition(rounds > 0 && keyLength > 0)
        let stride = (keyLength + 31) / 32
        let amt = (keyLength + stride - 1) / stride
        let sha2pass = [UInt8](SHA512.hash(data: passphrase))
        var key = [UInt8](repeating: 0, count: keyLength)
        var remaining = keyLength
        var count: UInt32 = 1
        while remaining > 0 {
            var countSalt = salt
            countSalt.append(contentsOf: withUnsafeBytes(of: count.bigEndian) { Array($0) })
            var sha2salt = [UInt8](SHA512.hash(data: countSalt))
            var tmp = hash(sha2pass: sha2pass, sha2salt: sha2salt)
            var out = tmp
            for _ in 1..<rounds {
                sha2salt = [UInt8](SHA512.hash(data: Data(tmp)))
                tmp = hash(sha2pass: sha2pass, sha2salt: sha2salt)
                for i in 0..<32 {
                    out[i] ^= tmp[i]
                }
            }
            let take = min(amt, remaining)
            var copied = 0
            for i in 0..<take {
                let dest = i * stride + Int(count) - 1
                guard dest < keyLength else { break }
                key[dest] = out[i]
                copied += 1
            }
            remaining -= copied
            count += 1
        }
        return Data(key)
    }
}
