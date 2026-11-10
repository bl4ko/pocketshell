import Combine
import Foundation
import KeyKit
import Models
import SwiftUI

@MainActor
final class VoiceSync: ObservableObject {
    struct Vault {
        var get: (String) -> String?
        var set: (String, String) -> Void
        var delete: (String) -> Void

        static var keychain: Vault {
            Vault(
                get: { PasswordVault.get(account: $0) },
                set: { PasswordVault.set($0, account: $1) },
                delete: { PasswordVault.delete(account: $0) })
        }
    }

    static let settingKeys = [
        BrainSettings.baseURLKey, BrainSettings.modelKey, BrainSettings.earsKey, BrainSettings.mouthKey,
        BrainSettings.sonioxVoiceKey, BrainSettings.turnEndKey,
    ]
    static let keyAccounts = [BrainSettings.apiKeyAccount, BrainSettings.sonioxKeyAccount]
    static let settingsStateKey = "pocketshell.voiceSync.settings"
    static let keyMarksKey = "pocketshell.voiceSync.keyMarks"

    @Published private(set) var keysRevision = 0
    var onSettingsEdit: () -> Void = {}
    var onKeysEdit: () -> Void = {}

    private let defaults: UserDefaults
    private let vault: Vault
    private var state: SyncedFields?
    private var marks: SyncedFields
    private var observer: AnyCancellable?

    init(defaults: UserDefaults = .standard, vault: Vault = .keychain) {
        self.defaults = defaults
        self.vault = vault
        state = Self.load(Self.settingsStateKey, from: defaults)
        marks = Self.load(Self.keyMarksKey, from: defaults) ?? SyncedFields()
        settings()
        observer = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.noteEdits() } }
    }

    @discardableResult
    func settings(now: Date = Date()) -> SyncedFields {
        let current = Dictionary(uniqueKeysWithValues: Self.settingKeys.map { ($0, defaults.string(forKey: $0) ?? "") })
        let noted = (state ?? SyncedFields()).recording(current, at: state == nil ? SyncedFields.unsynced : now)
        if noted != state {
            state = noted
            Self.save(noted, Self.settingsStateKey, to: defaults)
        }
        return noted
    }

    @discardableResult
    func receive(settings remote: SyncedFields?) -> Bool {
        let remote = remote ?? SyncedFields()
        let local = settings()
        let merged = local.merged(with: remote)
        if merged != local {
            state = merged
            Self.save(merged, Self.settingsStateKey, to: defaults)
            for key in Self.settingKeys {
                let value = merged.fields[key]?.value ?? ""
                guard value != (defaults.string(forKey: key) ?? "") else { continue }
                if value.isEmpty {
                    defaults.removeObject(forKey: key)
                } else {
                    defaults.set(value, forKey: key)
                }
            }
        }
        return merged != remote
    }

    func keys() -> SyncedFields {
        SyncedFields.secrets(
            Dictionary(uniqueKeysWithValues: Self.keyAccounts.map { ($0, vault.get($0) ?? "") }), marks: marks)
    }

    func setKey(_ key: String, account: String, now: Date = Date()) {
        store(key, account: account)
        marks.set(key.isEmpty ? "" : SyncedFields.saved, for: account, at: now)
        Self.save(marks, Self.keyMarksKey, to: defaults)
        keysRevision += 1
        onKeysEdit()
    }

    @discardableResult
    func receive(keys remote: SyncedFields?) -> Bool {
        let remote = remote ?? SyncedFields()
        let local = keys()
        let merged = local.merged(with: remote)
        if merged != local {
            for account in Self.keyAccounts {
                guard let key = merged.fields[account]?.value, key != (vault.get(account) ?? "") else { continue }
                store(key, account: account)
            }
            marks = merged.marks
            Self.save(marks, Self.keyMarksKey, to: defaults)
            keysRevision += 1
        }
        return Self.keyAccounts.contains { merged.fields[$0] != remote.fields[$0] }
    }

    private func noteEdits() {
        let before = state
        if settings() != before { onSettingsEdit() }
    }

    private func store(_ key: String, account: String) {
        if key.isEmpty {
            vault.delete(account)
        } else {
            vault.set(key, account)
        }
    }

    private static func load(_ key: String, from defaults: UserDefaults) -> SyncedFields? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SyncedFields.self, from: $0) }
    }

    private static func save(_ fields: SyncedFields, _ key: String, to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(fields), forKey: key)
    }
}

struct VoiceSyncNote: View {
    @AppStorage(AppSettings.iCloudSyncKey) private var sync = false
    @AppStorage(AppSettings.iCloudCredentialsSyncKey) private var credentials = false
    var text: String

    var body: some View {
        Text(text + " " + Self.note(sync: sync, credentials: credentials))
    }

    static func note(sync: Bool, credentials: Bool) -> String {
        guard sync else {
            return "Settings and keys stay on this device. Turn on iCloud Keychain sync under Config to share them."
        }
        return credentials
            ? "Settings and keys sync through iCloud Keychain."
            : "Settings sync through iCloud Keychain. Keys stay on this device unless Config also syncs credentials."
    }
}
