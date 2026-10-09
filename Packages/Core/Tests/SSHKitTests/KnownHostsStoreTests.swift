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

@Test func unknownHostIsFirstUse() throws {
    let store = tempStore()
    #expect(try store.check(host: "192.0.2.10", port: 22, publicKeyLine: keyA) == .firstUse)
}

@Test func trustedKeyMatches() throws {
    let store = tempStore()
    try store.trust(host: "192.0.2.10", port: 22, publicKeyLine: keyA)
    #expect(try store.check(host: "192.0.2.10", port: 22, publicKeyLine: keyA) == .match)
}

@Test func differentKeyMismatches() throws {
    let store = tempStore()
    try store.trust(host: "192.0.2.10", port: 22, publicKeyLine: keyA)
    let verdict = try store.check(host: "192.0.2.10", port: 22, publicKeyLine: keyB)
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
    #expect(try store.check(host: "192.0.2.11", port: 22, publicKeyLine: keyB) == .firstUse)
}

@Test func persistsAcrossInstances() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("known-hosts-\(UUID().uuidString).json")
    try KnownHostsStore(fileURL: url).trust(host: "h", port: 2222, publicKeyLine: keyA)
    #expect(try KnownHostsStore(fileURL: url).check(host: "h", port: 2222, publicKeyLine: keyA) == .match)
}

@Test func fingerprintMatchesOpenSSHFormat() {
    let fingerprint = KnownHostsStore.fingerprint(publicKeyLine: keyA)
    #expect(fingerprint.hasPrefix("SHA256:"))
    #expect(!fingerprint.hasSuffix("="))
}

@Test func entriesReturnsAllStoredFingerprints() throws {
    let store = tempStore()
    try store.trust(host: "a", port: 22, publicKeyLine: keyA)
    try store.trust(host: "b", port: 2222, publicKeyLine: keyB)
    let entries = try store.entries()
    #expect(entries.count == 2)
    #expect(entries["a:22"] == KnownHostsStore.fingerprint(publicKeyLine: keyA))
}

@Test func mergeAddsWithoutOverwritingExisting() throws {
    let store = tempStore()
    try store.trust(host: "a", port: 22, publicKeyLine: keyA)
    let existing = KnownHostsStore.fingerprint(publicKeyLine: keyA)
    try store.merge(["a:22": "SHA256:other", "c:22": "SHA256:new"])
    let entries = try store.entries()
    #expect(entries["a:22"] == existing)
    #expect(entries["c:22"] == "SHA256:new")
}

@Test func corruptFileFailsClosedAndIsNotOverwritten() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("known-hosts-\(UUID().uuidString).json")
    let corrupt = Data("{not json".utf8)
    try corrupt.write(to: url)
    let store = KnownHostsStore(fileURL: url)
    #expect(throws: (any Error).self) { try store.check(host: "h", port: 22, publicKeyLine: keyA) }
    #expect(throws: (any Error).self) { try store.trust(host: "h", port: 22, publicKeyLine: keyA) }
    #expect(throws: (any Error).self) { try store.merge(["x:22": "SHA256:x"]) }
    #expect(try Data(contentsOf: url) == corrupt)
}

@Test func unreadableFileFailsClosed() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("known-hosts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let store = KnownHostsStore(fileURL: url)
    #expect(throws: (any Error).self) { try store.check(host: "h", port: 22, publicKeyLine: keyA) }
}

@Test func concurrentTrustsAllPersist() async throws {
    let store = tempStore()
    let count = 40
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<count {
            group.addTask {
                try store.trust(host: "host\(index)", port: 22, publicKeyLine: keyA)
            }
        }
        try await group.waitForAll()
    }
    #expect(try store.entries().count == count)
}
