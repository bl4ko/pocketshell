import Crypto
import Foundation
import Security

public enum DeviceKeyMaterial: Sendable {
    case enclave(SecureEnclave.P256.Signing.PrivateKey)
    case software(P256.Signing.PrivateKey)
    case ed25519(Curve25519.Signing.PrivateKey)

    public var publicKeyRawRepresentation: Data {
        switch self {
        case .enclave(let key): key.publicKey.rawRepresentation
        case .software(let key): key.publicKey.rawRepresentation
        case .ed25519(let key): key.publicKey.rawRepresentation
        }
    }

    public func openSSHPublicKeyLine(comment: String) -> String {
        switch self {
        case .enclave(let key): OpenSSHPublicKey.line(for: key.publicKey, comment: comment)
        case .software(let key): OpenSSHPublicKey.line(for: key.publicKey, comment: comment)
        case .ed25519(let key): OpenSSHPublicKey.line(forEd25519: key.publicKey, comment: comment)
        }
    }
}

public struct DeviceKeyStore: Sendable {
    public enum StoreError: Error {
        case keychain(OSStatus)
        case corruptStoredKey
    }

    private let service: String

    public init(service: String = "com.bl4ko.pocketshell.keys") {
        self.service = service
    }

    public func loadOrCreate(
        tag: String,
        preferEnclave: Bool = SecureEnclave.isAvailable
    ) throws -> DeviceKeyMaterial {
        if let existing = try load(tag: tag) {
            return existing
        }
        let material: DeviceKeyMaterial
        var stored: Data
        if preferEnclave {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            material = .enclave(key)
            stored = Data([0x01]) + key.dataRepresentation
        } else {
            let key = P256.Signing.PrivateKey()
            material = .software(key)
            stored = Data([0x02]) + key.rawRepresentation
        }
        try save(tag: tag, data: stored)
        return material
    }

    public func load(tag: String) throws -> DeviceKeyMaterial? {
        var query = baseQuery(tag: tag)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let marker = data.first else {
            throw StoreError.keychain(status)
        }
        let body = data.dropFirst()
        switch marker {
        case 0x01:
            return .enclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body))
        case 0x02:
            return .software(try P256.Signing.PrivateKey(rawRepresentation: body))
        case 0x03:
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: body))
        default:
            throw StoreError.corruptStoredKey
        }
    }

    public func saveImported(tag: String, key: DeviceKeyMaterial) throws {
        let stored: Data
        switch key {
        case .enclave(let key): stored = Data([0x01]) + key.dataRepresentation
        case .software(let key): stored = Data([0x02]) + key.rawRepresentation
        case .ed25519(let key): stored = Data([0x03]) + key.rawRepresentation
        }
        try delete(tag: tag)
        try save(tag: tag, data: stored)
    }

    public func delete(tag: String) throws {
        let status = SecItemDelete(baseQuery(tag: tag) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    private func save(tag: String, data: Data) throws {
        var query = baseQuery(tag: tag)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychain(status)
        }
    }

    private func baseQuery(tag: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tag,
        ]
    }
}
