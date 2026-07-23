import Crypto
import Foundation

public struct PortablePrivateKey: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case p256
        case ed25519
    }

    public let kind: Kind
    public let rawRepresentation: Data

    public init?(_ key: DeviceKeyMaterial) {
        switch key {
        case .enclave:
            return nil
        case .software(let key):
            kind = .p256
            rawRepresentation = key.rawRepresentation
        case .ed25519(let key):
            kind = .ed25519
            rawRepresentation = key.rawRepresentation
        }
    }

    public func keyMaterial() throws -> DeviceKeyMaterial {
        switch kind {
        case .p256:
            return .software(try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation))
        case .ed25519:
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation))
        }
    }

    public static func stablePreferred(_ first: Self?, _ second: Self?) -> Self? {
        guard let first else { return second }
        guard let second else { return first }
        guard let firstKey = try? first.keyMaterial() else { return second }
        guard let secondKey = try? second.keyMaterial() else { return first }
        return firstKey.publicKeyRawRepresentation.lexicographicallyPrecedes(secondKey.publicKeyRawRepresentation)
            ? second
            : first
    }
}
