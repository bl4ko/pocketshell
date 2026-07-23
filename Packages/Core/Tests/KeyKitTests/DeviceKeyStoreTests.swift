import Crypto
import Foundation
import Testing

@testable import KeyKit

@Test func loadOrCreatePersistsSameKeyAcrossCalls() throws {
    let tag = "test-\(UUID().uuidString)"
    let store = DeviceKeyStore(service: "com.bl4ko.pocketshell.tests")
    defer { try? store.delete(tag: tag) }

    let first = try store.loadOrCreate(tag: tag, preferEnclave: false)
    let second = try store.loadOrCreate(tag: tag, preferEnclave: false)
    #expect(first.publicKeyRawRepresentation == second.publicKeyRawRepresentation)
}

@Test func softwareKeyKindWhenEnclaveNotPreferred() throws {
    let tag = "test-\(UUID().uuidString)"
    let store = DeviceKeyStore(service: "com.bl4ko.pocketshell.tests")
    defer { try? store.delete(tag: tag) }

    let key = try store.loadOrCreate(tag: tag, preferEnclave: false)
    guard case .software = key else {
        Issue.record("expected software key")
        return
    }
}

@Test func deleteRemovesKey() throws {
    let tag = "test-\(UUID().uuidString)"
    let store = DeviceKeyStore(service: "com.bl4ko.pocketshell.tests")

    let first = try store.loadOrCreate(tag: tag, preferEnclave: false)
    try store.delete(tag: tag)
    let second = try store.loadOrCreate(tag: tag, preferEnclave: false)
    defer { try? store.delete(tag: tag) }
    #expect(first.publicKeyRawRepresentation != second.publicKeyRawRepresentation)
}

@Test func signProducesValidSignature() throws {
    let tag = "test-\(UUID().uuidString)"
    let store = DeviceKeyStore(service: "com.bl4ko.pocketshell.tests")
    defer { try? store.delete(tag: tag) }

    let key = try store.loadOrCreate(tag: tag, preferEnclave: false)
    guard case .software(let privateKey) = key else {
        Issue.record("expected software key")
        return
    }
    let message = Data("hello".utf8)
    let signature = try privateKey.signature(for: message)
    #expect(privateKey.publicKey.isValidSignature(signature, for: message))
}

@Test func portablePrivateKeyRoundtrip() throws {
    let original = DeviceKeyMaterial.ed25519(Curve25519.Signing.PrivateKey())
    let restored = try #require(PortablePrivateKey(original)).keyMaterial()
    #expect(restored.publicKeyRawRepresentation == original.publicKeyRawRepresentation)
}

@Test func portableP256PrivateKeyRoundtrip() throws {
    let original = DeviceKeyMaterial.software(P256.Signing.PrivateKey())
    let restored = try #require(PortablePrivateKey(original)).keyMaterial()
    #expect(restored.publicKeyRawRepresentation == original.publicKeyRawRepresentation)
}

@Test func sharedKeyPreferenceIsStableAcrossMergeOrder() throws {
    let first = try #require(PortablePrivateKey(.software(P256.Signing.PrivateKey())))
    let second = try #require(PortablePrivateKey(.software(P256.Signing.PrivateKey())))
    let preferred = try #require(PortablePrivateKey.stablePreferred(first, second))
    let reversed = try #require(PortablePrivateKey.stablePreferred(second, first))

    #expect(try preferred.keyMaterial().publicKeyRawRepresentation == reversed.keyMaterial().publicKeyRawRepresentation)
}
