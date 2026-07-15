import CommonCrypto
import Crypto
import Foundation

public enum OpenSSHPrivateKey {
    public enum ParseError: Error, Equatable {
        case notOpenSSHKey
        case encrypted
        case wrongPassphrase
        case unsupportedCipher(String)
        case unsupportedKeyType(String)
        case malformed
    }

    private static let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let footer = "-----END OPENSSH PRIVATE KEY-----"
    private static let magic = "openssh-key-v1\0"

    public static func parse(_ text: String, passphrase: String? = nil) throws -> DeviceKeyMaterial {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let headerRange = trimmed.range(of: header),
            let footerRange = trimmed.range(of: footer)
        else { throw ParseError.notOpenSSHKey }
        let base64 = trimmed[headerRange.upperBound..<footerRange.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let blob = Data(base64Encoded: base64) else { throw ParseError.notOpenSSHKey }

        var reader = WireReader(blob)
        guard reader.readRaw(magic.utf8.count).map({ String(decoding: $0, as: UTF8.self) }) == magic else {
            throw ParseError.notOpenSSHKey
        }
        guard let cipher = reader.readString(),
            let kdfName = reader.readString(),
            let kdfOptions = reader.readData(),
            let keyCount = reader.readUInt32()
        else { throw ParseError.malformed }
        guard keyCount == 1 else { throw ParseError.malformed }
        guard reader.readData() != nil, var privateSection = reader.readData() else {
            throw ParseError.malformed
        }

        if cipher != "none" {
            let passphrase = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !passphrase.isEmpty else { throw ParseError.encrypted }
            privateSection = try decrypt(
                privateSection,
                cipher: cipher,
                kdfName: kdfName,
                kdfOptions: kdfOptions,
                passphrase: passphrase
            )
        }

        var section = WireReader(privateSection)
        guard let check1 = section.readUInt32(), let check2 = section.readUInt32() else {
            throw ParseError.malformed
        }
        guard check1 == check2 else {
            throw cipher == "none" ? ParseError.malformed : ParseError.wrongPassphrase
        }
        guard let keyType = section.readString() else { throw ParseError.malformed }

        switch keyType {
        case "ssh-ed25519":
            guard section.readData() != nil,
                let privateBlob = section.readData(),
                privateBlob.count == 64
            else { throw ParseError.malformed }
            let seed = privateBlob.prefix(32)
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
                throw ParseError.malformed
            }
            return .ed25519(key)
        case "ecdsa-sha2-nistp256":
            guard section.readString() == "nistp256",
                section.readData() != nil,
                var scalar = section.readData()
            else { throw ParseError.malformed }
            while scalar.first == 0 { scalar.removeFirst() }
            guard scalar.count <= 32 else { throw ParseError.malformed }
            let padded = Data(repeating: 0, count: 32 - scalar.count) + scalar
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: padded) else {
                throw ParseError.malformed
            }
            return .software(key)
        default:
            throw ParseError.unsupportedKeyType(keyType)
        }
    }

    private static func decrypt(
        _ ciphertext: Data,
        cipher: String,
        kdfName: String,
        kdfOptions: Data,
        passphrase: String
    ) throws -> Data {
        let (keyLength, mode): (Int, CCMode) =
            switch cipher {
            case "aes256-ctr": (32, CCMode(kCCModeCTR))
            case "aes192-ctr": (24, CCMode(kCCModeCTR))
            case "aes128-ctr": (16, CCMode(kCCModeCTR))
            case "aes256-cbc": (32, CCMode(kCCModeCBC))
            case "aes128-cbc": (16, CCMode(kCCModeCBC))
            default: throw ParseError.unsupportedCipher(cipher)
            }
        guard kdfName == "bcrypt" else { throw ParseError.unsupportedCipher("\(cipher)/\(kdfName)") }

        var options = WireReader(kdfOptions)
        guard let salt = options.readData(), let rounds = options.readUInt32(), rounds > 0 else {
            throw ParseError.malformed
        }
        let ivLength = 16
        let derived = BcryptPBKDF.derive(
            passphrase: Data(passphrase.utf8),
            salt: salt,
            rounds: Int(rounds),
            keyLength: keyLength + ivLength
        )
        let key = derived.prefix(keyLength)
        let iv = derived.suffix(ivLength)

        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    mode,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    keyBytes.count,
                    nil,
                    0,
                    0,
                    mode == CCMode(kCCModeCTR) ? CCModeOptions(kCCModeOptionCTR_BE) : 0,
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else { throw ParseError.malformed }
        defer { CCCryptorRelease(cryptor) }

        var plaintext = Data(count: ciphertext.count)
        var written = 0
        let updateStatus = plaintext.withUnsafeMutableBytes { outBytes in
            ciphertext.withUnsafeBytes { inBytes in
                CCCryptorUpdate(
                    cryptor,
                    inBytes.baseAddress,
                    inBytes.count,
                    outBytes.baseAddress,
                    outBytes.count,
                    &written
                )
            }
        }
        guard updateStatus == kCCSuccess, written == ciphertext.count else {
            throw ParseError.wrongPassphrase
        }
        return plaintext
    }
}

private struct WireReader {
    private var data: Data

    init(_ data: Data) {
        self.data = data
    }

    mutating func readRaw(_ count: Int) -> Data? {
        guard data.count >= count else { return nil }
        let value = data.prefix(count)
        data = data.dropFirst(count)
        return Data(value)
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readRaw(4) else { return nil }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func readData() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readRaw(Int(length))
    }

    mutating func readString() -> String? {
        readData().map { String(decoding: $0, as: UTF8.self) }
    }
}
