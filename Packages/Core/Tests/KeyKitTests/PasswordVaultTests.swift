import Foundation
import Testing

@testable import KeyKit

@Test func setGetRoundtrip() {
    let account = "test-\(UUID().uuidString)"
    defer { PasswordVault.delete(account: account) }

    PasswordVault.set("s3cret", account: account)
    #expect(PasswordVault.get(account: account) == "s3cret")
}

@Test func setOverwritesExistingPassword() {
    let account = "test-\(UUID().uuidString)"
    defer { PasswordVault.delete(account: account) }

    PasswordVault.set("first", account: account)
    PasswordVault.set("second", account: account)
    #expect(PasswordVault.get(account: account) == "second")
}

@Test func getMissingAccountReturnsNil() {
    #expect(PasswordVault.get(account: "missing-\(UUID().uuidString)") == nil)
}

@Test func deleteRemovesPassword() {
    let account = "test-\(UUID().uuidString)"
    PasswordVault.set("gone", account: account)
    PasswordVault.delete(account: account)
    #expect(PasswordVault.get(account: account) == nil)
}
