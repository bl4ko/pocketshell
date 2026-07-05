import Foundation
import Testing
@testable import SSHKit

private func tempStore() -> KnownHostsStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("known-hosts-\(UUID().uuidString).json")
    return KnownHostsStore(fileURL: url)
}

private let keyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKq7fXeQdOTBjLKk9Yyoo3XU4dWnCT6r7cM+RJ9dLbAe"
private let keyB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFhbnFTQb8zGKf22dBN9pd6GfJ7yQ1t8LDPGWJ4c2mNi"

@Test func unknownHostIsFirstUse() {
    let store = tempStore()
    #expect(store.check(host: "192.0.2.10", port: 22, publicKeyLine: keyA) == .firstUse)
}

@Test func trustedKeyMatches() throws {
    let store = tempStore()
    try store.trust(host: "192.0.2.10", port: 22, publicKeyLine: keyA)
    #expect(store.check(host: "192.0.2.10", port: 22, publicKeyLine: keyA) == .match)
}

@Test func differentKeyMismatches() throws {
    let store = tempStore()
    try store.trust(host: "192.0.2.10", port: 22, publicKeyLine: keyA)
    let verdict = store.check(host: "192.0.2.10", port: 22, publicKeyLine: keyB)
    guard case .mismatch(let stored, let presented) = verdict else {
        Issue.record("expected mismatch, got \(verdict)")
        return
    }
    #expect(stored.hasPrefix("SHA256:"))
    #expect(presented.hasPrefix("SHA256:"))
    #expect(stored != presented)
}

@Test func samePortDifferentHostIsIndependent() throws {
    let store = tempStore()
    try store.trust(host: "192.0.2.10", port: 22, publicKeyLine: keyA)
    #expect(store.check(host: "192.0.2.11", port: 22, publicKeyLine: keyB) == .firstUse)
}

@Test func persistsAcrossInstances() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("known-hosts-\(UUID().uuidString).json")
    try KnownHostsStore(fileURL: url).trust(host: "h", port: 2222, publicKeyLine: keyA)
    #expect(KnownHostsStore(fileURL: url).check(host: "h", port: 2222, publicKeyLine: keyA) == .match)
}

@Test func fingerprintMatchesOpenSSHFormat() {
    let fingerprint = KnownHostsStore.fingerprint(publicKeyLine: keyA)
    #expect(fingerprint.hasPrefix("SHA256:"))
    #expect(!fingerprint.hasSuffix("="))
}
