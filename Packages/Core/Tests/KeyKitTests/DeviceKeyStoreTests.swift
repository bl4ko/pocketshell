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
    #expect(first.publicKey.rawRepresentation == second.publicKey.rawRepresentation)
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
    #expect(first.publicKey.rawRepresentation != second.publicKey.rawRepresentation)
}

@Test func signProducesValidSignature() throws {
    let tag = "test-\(UUID().uuidString)"
    let store = DeviceKeyStore(service: "com.bl4ko.pocketshell.tests")
    defer { try? store.delete(tag: tag) }

    let key = try store.loadOrCreate(tag: tag, preferEnclave: false)
    let message = Data("hello".utf8)
    let signature = try key.signature(for: message)
    #expect(key.publicKey.isValidSignature(signature, for: message))
}
