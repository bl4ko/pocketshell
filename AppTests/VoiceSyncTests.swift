import Foundation
import Models
import Testing

@testable import pocketshell

@MainActor
struct VoiceSyncTests {
    @MainActor
    final class Keychain {
        var items: [String: String] = [:]
        var vault: VoiceSync.Vault {
            VoiceSync.Vault(
                get: { self.items[$0] }, set: { self.items[$1] = $0 }, delete: { self.items[$0] = nil })
        }
    }

    @MainActor
    final class Device {
        let name = "voice-sync-\(UUID().uuidString)"
        let defaults: UserDefaults
        let keychain = Keychain()
        private(set) lazy var sync = VoiceSync(defaults: defaults, vault: keychain.vault)

        init(_ settings: [String: String] = [:]) {
            defaults = UserDefaults(suiteName: name)!
            for (key, value) in settings { defaults.set(value, forKey: key) }
        }

        func relaunched() -> VoiceSync { VoiceSync(defaults: defaults, vault: keychain.vault) }

        var settings: [String: String] {
            VoiceSync.settingKeys.reduce(into: [:]) { $0[$1] = defaults.string(forKey: $1) }
        }

        deinit { UserDefaults.standard.removePersistentDomain(forName: name) }
    }

    private let configured = [
        BrainSettings.baseURLKey: "https://example.com/v1", BrainSettings.modelKey: "small",
        BrainSettings.earsKey: "soniox", BrainSettings.mouthKey: "soniox",
        BrainSettings.sonioxVoiceKey: "Grace", BrainSettings.turnEndKey: "fast",
    ]
    private let later = Date().addingTimeInterval(3600)

    @Test func anEmptyDeviceThatWritesFirstDoesNotWipeTheConfiguredOne() {
        let phone = Device(configured)
        let pad = Device()

        #expect(!pad.sync.receive(settings: nil))
        let cloud = pad.sync.settings()
        #expect(cloud == SyncedFields())

        #expect(phone.sync.receive(settings: cloud), "the phone must upload what the cloud lacks")
        #expect(phone.settings == configured)

        #expect(!pad.sync.receive(settings: phone.sync.settings()))
        #expect(pad.settings == configured)
        #expect(pad.relaunched().settings() == phone.sync.settings())
    }

    @Test func anEditReachesTheOtherDeviceAndAClearedFieldToo() {
        let phone = Device(configured)
        let pad = Device()
        pad.sync.receive(settings: phone.sync.settings())

        pad.defaults.set("large", forKey: BrainSettings.modelKey)
        pad.defaults.removeObject(forKey: BrainSettings.sonioxVoiceKey)
        let edited = pad.sync.settings(now: later)
        #expect(edited.fields[BrainSettings.modelKey] == .init(value: "large", updatedAt: later))

        #expect(!phone.sync.receive(settings: edited))
        #expect(phone.settings[BrainSettings.modelKey] == "large")
        #expect(phone.settings[BrainSettings.sonioxVoiceKey] == nil)
        #expect(phone.settings[BrainSettings.baseURLKey] == "https://example.com/v1")
    }

    @Test func settingsOutsideTheSyncedSetStayLocal() {
        let phone = Device([BrainSettings.voiceKey: "com.apple.voice.example", BrainSettings.modelKey: "small"])
        phone.defaults.set(true, forKey: BrainSettings.saveAudioKey)
        #expect(Array(phone.sync.settings().fields.keys) == [BrainSettings.modelKey])
    }

    @Test func onlyAUserEditAsksForAnUpload() async throws {
        let phone = Device(configured)
        let pad = Device()
        var uploads = 0
        pad.sync.onSettingsEdit = { uploads += 1 }

        pad.sync.receive(settings: phone.sync.settings())
        try await Task.sleep(for: .seconds(2))
        #expect(uploads == 0, "received values must not be uploaded again")

        pad.defaults.set("large", forKey: BrainSettings.modelKey)
        for _ in 0..<50 where uploads == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(uploads == 1)
        #expect(pad.sync.settings().fields[BrainSettings.modelKey]?.value == "large")
    }

    @Test func keysSyncAndRemovalPropagates() {
        let phone = Device()
        let pad = Device()
        var uploads = 0
        var shown = 0
        phone.sync.onKeysEdit = { uploads += 1 }
        let watching = pad.sync.$keysRevision.dropFirst().sink { _ in shown += 1 }
        defer { watching.cancel() }

        phone.sync.setKey("secret-a", account: BrainSettings.apiKeyAccount)
        phone.sync.setKey("secret-s", account: BrainSettings.sonioxKeyAccount)
        #expect(uploads == 2)

        #expect(!pad.sync.receive(keys: phone.sync.keys()))
        #expect(pad.keychain.items == phone.keychain.items)
        #expect(shown == 1, "an open Settings screen must refresh its Saved rows")

        pad.sync.setKey("", account: BrainSettings.apiKeyAccount, now: later)
        #expect(!phone.sync.receive(keys: pad.sync.keys()))
        #expect(phone.keychain.items == [BrainSettings.sonioxKeyAccount: "secret-s"])

        #expect(phone.sync.receive(keys: nil), "an older build dropped the block: upload it again")
        #expect(phone.keychain.items == [BrainSettings.sonioxKeyAccount: "secret-s"])
    }

    @Test func aDeviceWithoutKeysNeverRemovesTheCloudKeys() {
        let phone = Device()
        phone.keychain.items[BrainSettings.apiKeyAccount] = "secret-a"
        let pad = Device()

        #expect(pad.sync.keys() == SyncedFields())
        #expect(phone.sync.receive(keys: pad.sync.keys()))
        #expect(phone.keychain.items[BrainSettings.apiKeyAccount] == "secret-a")

        pad.sync.receive(keys: phone.sync.keys())
        pad.keychain.items = [:]
        let restored = pad.relaunched()
        #expect(restored.keys() == SyncedFields(), "a lost Keychain is not a removal")
        restored.receive(keys: phone.sync.keys())
        #expect(pad.keychain.items[BrainSettings.apiKeyAccount] == "secret-a")
    }

    @Test func keysNeverLeaveTheKeychainForTheConfigOrDefaults() throws {
        let phone = Device(configured)
        phone.sync.setKey("secret-a", account: BrainSettings.apiKeyAccount)
        phone.sync.setKey("secret-s", account: BrainSettings.sonioxKeyAccount)
        let store = AppStore(voice: phone.sync)

        let config = store.exportConfig()
        #expect(Set((config.voice ?? SyncedFields()).fields.keys) == Set(VoiceSync.settingKeys))
        let exported = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(exported.contains("example.com"))
        let persisted = [VoiceSync.settingsStateKey, VoiceSync.keyMarksKey]
            .compactMap { phone.defaults.data(forKey: $0) }.map { String(decoding: $0, as: UTF8.self) }
        #expect(persisted.count == 2)
        for text in persisted + [exported] {
            #expect(!text.contains("secret-a"))
            #expect(!text.contains("secret-s"))
        }
    }

    @Test func footerTellsWhereSettingsAndKeysLive() {
        #expect(VoiceSyncNote.note(sync: false, credentials: true).contains("stay on this device"))
        #expect(VoiceSyncNote.note(sync: true, credentials: false).contains("Keys stay on this device"))
        #expect(VoiceSyncNote.note(sync: true, credentials: true) == "Settings and keys sync through iCloud Keychain.")
    }
}
