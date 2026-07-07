import Crypto
import Foundation

public enum OpenSSHPrivateKey {
    public enum ParseError: Error, Equatable {
        case notOpenSSHKey
        case encrypted
        case unsupportedKeyType(String)
        case malformed
    }

    private static let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let footer = "-----END OPENSSH PRIVATE KEY-----"
    private static let magic = "openssh-key-v1\0"

    public static func parse(_ text: String) throws -> DeviceKeyMaterial {
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
              reader.readString() != nil,
              reader.readString() != nil,
              let keyCount = reader.readUInt32()
        else { throw ParseError.malformed }
        guard cipher == "none" else { throw ParseError.encrypted }
        guard keyCount == 1 else { throw ParseError.malformed }
        guard reader.readData() != nil, let privateSection = reader.readData() else {
            throw ParseError.malformed
        }

        var section = WireReader(privateSection)
        guard let check1 = section.readUInt32(), let check2 = section.readUInt32(), check1 == check2,
              let keyType = section.readString()
        else { throw ParseError.malformed }

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
