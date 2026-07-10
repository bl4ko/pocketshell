import Foundation
import Testing
@testable import Models

@Test func hostConfigCodableRoundTrip() throws {
    let host = HostConfig(
        name: "mac-mini",
        hostname: "192.0.2.10",
        username: "alice",
        keyTag: "device-key",
        tmuxSession: "claude"
    )
    let data = try JSONEncoder().encode(host)
    let decoded = try JSONDecoder().decode(HostConfig.self, from: data)
    #expect(decoded == host)
}

@Test func hostConfigGroupRoundTripsAndDefaultsNil() throws {
    var host = HostConfig(name: "m", hostname: "h", username: "u", keyTag: "k")
    #expect(host.group == nil)
    host.group = "homelab"
    let data = try JSONEncoder().encode(host)
    let decoded = try JSONDecoder().decode(HostConfig.self, from: data)
    #expect(decoded.group == "homelab")

    let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"a","hostname":"b","port":22,"username":"c","keyTag":"d"}"#.utf8)
    let old = try JSONDecoder().decode(HostConfig.self, from: legacy)
    #expect(old.group == nil)
}

@Test func snippetCodableRoundTrip() throws {
    let snippet = Snippet(name: "launch all", command: "~/.claude/scripts/launch-all.sh", runMode: .execAndShowOutput)
    let data = try JSONEncoder().encode(snippet)
    let decoded = try JSONDecoder().decode(Snippet.self, from: data)
    #expect(decoded == snippet)
}

@Test func toolbarKeyCodableRoundTripIncludingSequence() throws {
    let key = ToolbarKey(label: "C-b", action: .sequence("\u{02}"))
    let data = try JSONEncoder().encode(key)
    let decoded = try JSONDecoder().decode(ToolbarKey.self, from: data)
    #expect(decoded == key)
}

@Test func defaultToolbarHasEscCtrlTabArrows() {
    let labels = ToolbarKey.defaults.map(\.label)
    #expect(labels.contains("esc"))
    #expect(labels.contains("ctrl"))
    #expect(labels.contains("tab"))
    #expect(ToolbarKey.defaults.contains { $0.action == .arrowUp })
}

@Test func defaultToolbarHasTermiusQuickKeys() {
    let actions = ToolbarKey.defaults.map(\.action)
    #expect(actions.contains(.sequence("\u{03}")))
    #expect(actions.contains(.sequence("\u{04}")))
    #expect(actions.contains(.sequence("\u{1a}")))
    #expect(actions.contains(.sequence("\u{1b}[H")))
    #expect(actions.contains(.sequence("\u{1b}[F")))
    #expect(actions.contains(.sequence("\u{1b}[5~")))
    #expect(actions.contains(.sequence("\u{1b}[6~")))
    #expect(actions.contains(.sequence("/")))
    #expect(actions.contains(.sequence("-")))
}

@Test func importedKeyCodableRoundTrip() throws {
    let key = ImportedKey(name: "bitwarden-ed25519", tag: "imported-abc", publicKeyLine: "ssh-ed25519 AAAA test")
    let data = try JSONEncoder().encode(key)
    let decoded = try JSONDecoder().decode(ImportedKey.self, from: data)
    #expect(decoded == key)
}

@Test func pinnedActionsExcludedFromScrollRow() {
    let scroll = ToolbarKey.scrollRow(from: ToolbarKey.defaults)
    let actions = scroll.map(\.action)
    #expect(!actions.contains(.escape))
    #expect(!actions.contains(.ctrlModifier))
    #expect(!actions.contains(.arrowUp))
    #expect(!actions.contains(.arrowDown))
    #expect(!actions.contains(.arrowLeft))
    #expect(!actions.contains(.arrowRight))
    #expect(actions.contains(.tab))
    #expect(actions.contains(.sequence("\u{03}")))
}
