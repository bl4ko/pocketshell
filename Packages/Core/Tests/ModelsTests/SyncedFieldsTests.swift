import Foundation
import Models
import Testing

private let monday = Date(timeIntervalSince1970: 1_800_000_000)
private let tuesday = monday.addingTimeInterval(86_400)

private func fields(_ values: [String: String], at date: Date) -> SyncedFields {
    SyncedFields(fields: values.mapValues { SyncedFields.Field(value: $0, updatedAt: date) })
}

@Test func anEmptyDeviceTakesTheCloudAndNeverWipesAConfiguredOne() {
    let configured = ["endpoint": "https://example.com/v1", "model": "small", "mouth": "soniox"]
    let phone = SyncedFields().recording(configured, at: SyncedFields.unsynced)
    let pad = SyncedFields().recording(["endpoint": "", "model": "", "mouth": ""], at: SyncedFields.unsynced)
    #expect(pad == SyncedFields())

    #expect(phone.merged(with: pad) == phone)
    #expect(phone.merged(with: SyncedFields()) == phone)
    #expect(pad.merged(with: phone) == phone)
    #expect(pad.merged(with: phone).fields.mapValues(\.value) == configured)
}

@Test func theNewerEditWinsInBothDirections() {
    let old = fields(["model": "small", "endpoint": "https://example.com/v1"], at: monday)
    let new = fields(["model": "large"], at: tuesday)
    let merged = old.merged(with: new)
    #expect(merged == new.merged(with: old))
    #expect(merged.fields["model"]?.value == "large")
    #expect(merged.fields["endpoint"]?.value == "https://example.com/v1")
}

@Test func aRemovalPropagatesUntilALaterSave() {
    var phone = fields(["key": "secret-a"], at: monday)
    let pad = phone
    phone.set("", for: "key", at: tuesday)
    #expect(pad.merged(with: phone).fields["key"]?.value == "")

    var saved = pad
    saved.set("secret-b", for: "key", at: tuesday.addingTimeInterval(60))
    #expect(phone.merged(with: saved).fields["key"]?.value == "secret-b")
    #expect(saved.merged(with: phone).fields["key"]?.value == "secret-b")
}

@Test func equalStampsKeepAConfiguredValueOnEveryDevice() {
    let empty = fields(["model": ""], at: monday)
    let small = fields(["model": "small"], at: monday)
    let large = fields(["model": "large"], at: monday)
    #expect(empty.merged(with: small) == small)
    #expect(small.merged(with: empty) == small)
    #expect(small.merged(with: large) == large.merged(with: small))
}

@Test func anEditOutranksTheValueItReplacesWhenTheOtherClockRunsAhead() {
    let ahead = fields(["model": "small"], at: tuesday)
    let edited = ahead.recording(["model": "large"], at: monday)
    #expect(edited.fields["model"]?.updatedAt == tuesday.addingTimeInterval(1))
    #expect(ahead.merged(with: edited).fields["model"]?.value == "large")
}

@Test func recordingStampsOnlyTheFieldsThatChanged() {
    let before = fields(["model": "small", "endpoint": "https://example.com/v1"], at: monday)
    let after = before.recording(
        ["model": "small", "endpoint": "https://example.com/v2", "mouth": "", "ears": "soniox"], at: tuesday)
    #expect(after.fields["model"]?.updatedAt == monday)
    #expect(after.fields["endpoint"] == .init(value: "https://example.com/v2", updatedAt: tuesday))
    #expect(after.fields["ears"] == .init(value: "soniox", updatedAt: tuesday))
    #expect(after.fields["mouth"] == nil)
    #expect(after.recording(["endpoint": ""], at: tuesday).fields["endpoint"]?.value == "")
}

@Test func aLostKeychainIsNotARemoval() {
    let cloud = fields(["key": "secret-a"], at: monday)
    let restored = SyncedFields.secrets(["key": ""], marks: cloud.marks)
    #expect(restored == SyncedFields())
    #expect(restored.merged(with: cloud) == cloud)

    var marks = cloud.marks
    marks.set("", for: "key", at: tuesday)
    let removed = SyncedFields.secrets(["key": ""], marks: marks)
    #expect(removed.merged(with: cloud).fields["key"] == .init(value: "", updatedAt: tuesday))
}

@Test func aKeySavedBeforeSyncIsUnsyncedAndMarksHoldNoSecret() {
    let local = SyncedFields.secrets(["key": "secret-a", "other": ""], marks: SyncedFields())
    #expect(local.fields == ["key": .init(value: "secret-a", updatedAt: SyncedFields.unsynced)])
    #expect(local.marks.fields["key"]?.value == SyncedFields.saved)
    #expect(local.merged(with: fields(["key": "secret-b"], at: monday)).fields["key"]?.value == "secret-b")
}

private struct OlderConfigExport: Codable {
    var version: Int
    var hosts: [HostConfig]
    var vncHosts: [VNCHostConfig]
    var snippets: [Snippet]
    var toolbarKeys: [ToolbarKey]
    var knownHosts: [String: String]
    var workspace: WorkspaceConfig?
}

@Test func configWithoutAVoiceBlockDecodesAndOlderBuildsReadNewerConfig() throws {
    let older = #"{"version":1,"hosts":[],"vncHosts":[],"snippets":[],"toolbarKeys":[],"knownHosts":{}}"#
    #expect(try JSONDecoder().decode(ConfigExport.self, from: Data(older.utf8)).voice == nil)

    let voice = fields(["endpoint": "https://example.com/v1", "from-a-newer-build": "kept"], at: monday)
    let config = ConfigExport(hosts: [], vncHosts: [], snippets: [], toolbarKeys: [], knownHosts: [:], voice: voice)
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(ConfigExport.self, from: data) == config)
    #expect(try JSONDecoder().decode(OlderConfigExport.self, from: data).hosts.isEmpty)
    #expect(SyncedFields().merged(with: voice).fields["from-a-newer-build"]?.value == "kept")
}
