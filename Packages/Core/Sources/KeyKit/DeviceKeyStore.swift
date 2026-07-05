import Crypto
import Foundation
import Security

public enum DeviceKeyMaterial: Sendable {
    case enclave(SecureEnclave.P256.Signing.PrivateKey)
    case software(P256.Signing.PrivateKey)

    public var publicKey: P256.Signing.PublicKey {
        switch self {
        case .enclave(let key): key.publicKey
        case .software(let key): key.publicKey
        }
    }

    public func signature(for data: Data) throws -> P256.Signing.ECDSASignature {
        switch self {
        case .enclave(let key): try key.signature(for: data)
        case .software(let key): try key.signature(for: data)
        }
    }

    public func openSSHPublicKeyLine(comment: String) -> String {
        OpenSSHPublicKey.line(for: publicKey, comment: comment)
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
        default:
            throw StoreError.corruptStoredKey
        }
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
