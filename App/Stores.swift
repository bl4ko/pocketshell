import Crypto
import Foundation
import KeyKit
import Models
import SSHKit

struct JSONStore<T: Codable> {
    let url: URL

    init(filename: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pocketshell", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(filename)
    }

    func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private struct SyncedCredentials: Codable {
    var deviceKey: PortablePrivateKey?
    var importedKeys: [ImportedKey]
    var privateKeys: [String: PortablePrivateKey]
    var vncPasswords: [String: String]
}

@MainActor
final class AppStore: ObservableObject {
    static let deviceKeyTag = "pocketshell-device-key"

    @Published var hosts: [HostConfig] { didSet { hostsStore.save(hosts); saveConfigToCloud() } }
    @Published var vncHosts: [VNCHostConfig] { didSet { vncHostsStore.save(vncHosts); saveConfigToCloud() } }
    @Published var snippets: [Snippet] { didSet { snippetsStore.save(snippets); saveConfigToCloud() } }
    @Published var toolbarKeys: [ToolbarKey] { didSet { toolbarStore.save(toolbarKeys); saveConfigToCloud() } }
    @Published var importedKeys: [ImportedKey] {
        didSet { importedKeysStore.save(importedKeys); saveCredentialsToCloud() }
    }
    @Published var savedTabs: [String: [TabRecord]] {
        didSet {
            markWorkspaceChanged(old: oldValue, new: savedTabs)
            savedTabsStore.save(savedTabs)
            saveConfigToCloud()
        }
    }
    @Published var sessionOrder: [String: [String]] {
        didSet {
            markWorkspaceChanged(old: oldValue, new: sessionOrder)
            sessionOrderStore.save(sessionOrder)
            saveConfigToCloud()
        }
    }
    @Published private(set) var configSyncError: String?

    let keyStore = DeviceKeyStore()
    let knownHosts: KnownHostsStore

    private let hostsStore = JSONStore<[HostConfig]>(filename: "hosts.json")
    private let vncHostsStore = JSONStore<[VNCHostConfig]>(filename: "vnc-hosts.json")
    private let snippetsStore = JSONStore<[Snippet]>(filename: "snippets.json")
    private let toolbarStore = JSONStore<[ToolbarKey]>(filename: "toolbar.json")
    private let importedKeysStore = JSONStore<[ImportedKey]>(filename: "imported-keys.json")
    private let savedTabsStore = JSONStore<[String: [TabRecord]]>(filename: "tabs.json")
    private let sessionOrderStore = JSONStore<[String: [String]]>(filename: "session-order.json")
    private let workspaceUpdatedAtStore = JSONStore<[String: Date]>(filename: "workspace-updated-at.json")
    private var workspaceUpdatedAt: [String: Date]
    private var applyingConfig = false
    private var applyingCredentials = false

    private static let cloudConfigAccount = "config-v1"
    private static let cloudCredentialsAccount = "credentials-v1"

    init() {
        hosts = hostsStore.load() ?? []
        vncHosts = vncHostsStore.load() ?? []
        snippets = snippetsStore.load() ?? []
        toolbarKeys = toolbarStore.load() ?? ToolbarKey.defaults
        importedKeys = importedKeysStore.load() ?? []
        savedTabs = savedTabsStore.load() ?? [:]
        sessionOrder = sessionOrderStore.load() ?? [:]
        workspaceUpdatedAt = workspaceUpdatedAtStore.load() ?? [:]
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pocketshell", isDirectory: true)
        knownHosts = KnownHostsStore(fileURL: dir.appendingPathComponent("known-hosts.json"))
        if cloudSyncEnabled {
            setCloudSyncEnabled(true)
        }
    }

    private var cachedKey: DeviceKeyMaterial?

    func deviceKey() throws -> DeviceKeyMaterial {
        if let cachedKey { return cachedKey }
        let key: DeviceKeyMaterial
        if let injected = ProcessInfo.processInfo.environment["PS_TEST_KEY"],
            let raw = Data(base64Encoded: injected)
        {
            key = .software(try P256.Signing.PrivateKey(rawRepresentation: raw))
        } else {
            key = try keyStore.loadOrCreate(tag: Self.deviceKeyTag)
        }
        cachedKey = key
        return key
    }

    func key(for host: HostConfig) throws -> DeviceKeyMaterial {
        guard host.keyTag != Self.deviceKeyTag else { return try deviceKey() }
        if let imported = try keyStore.load(tag: host.keyTag) {
            return imported
        }
        return try deviceKey()
    }

    func importKey(name: String, privateKeyText: String, passphrase: String? = nil) throws -> ImportedKey {
        let material = try OpenSSHPrivateKey.parse(privateKeyText, passphrase: passphrase)
        let tag = "imported-\(UUID().uuidString)"
        try keyStore.saveImported(tag: tag, key: material)
        let key = ImportedKey(
            name: name,
            tag: tag,
            publicKeyLine: material.openSSHPublicKeyLine(comment: name)
        )
        importedKeys.append(key)
        return key
    }

    func deleteImportedKey(_ key: ImportedKey) {
        try? keyStore.delete(tag: key.tag)
        importedKeys.removeAll { $0.id == key.id }
    }

    func exportConfig() -> ConfigExport {
        ConfigExport(
            hosts: hosts,
            vncHosts: vncHosts,
            snippets: snippets,
            toolbarKeys: toolbarKeys,
            knownHosts: knownHosts.entries(),
            workspace: localWorkspace
        )
    }

    func applyConfig(_ config: ConfigExport) {
        applyingConfig = true
        hosts = ConfigExport.mergeByID(existing: hosts, incoming: config.hosts)
        vncHosts = ConfigExport.mergeByID(existing: vncHosts, incoming: config.vncHosts)
        snippets = ConfigExport.mergeByID(existing: snippets, incoming: config.snippets)
        toolbarKeys = ConfigExport.mergeByID(existing: toolbarKeys, incoming: config.toolbarKeys)
        if let workspace = config.workspace {
            applyWorkspace(WorkspaceConfig.merged(local: localWorkspace, remote: workspace))
        }
        try? knownHosts.merge(config.knownHosts)
        applyingConfig = false
        saveConfigToCloud()
    }

    func setCloudSyncEnabled(_ enabled: Bool) {
        guard enabled else { return }
        if let config = cloudConfig() {
            applyConfig(config)
        } else {
            saveConfigToCloud()
        }
        if credentialsSyncEnabled {
            setCredentialsSyncEnabled(true)
        }
    }

    func refreshCloudConfig() {
        if cloudSyncEnabled {
            receiveCloudConfig()
        }
        if credentialsSyncEnabled {
            receiveCloudCredentials()
        }
    }

    private var cloudSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.iCloudSyncKey)
    }

    private var credentialsSyncEnabled: Bool {
        cloudSyncEnabled && UserDefaults.standard.bool(forKey: AppSettings.iCloudCredentialsSyncKey)
    }

    private func cloudConfig() -> ConfigExport? {
        do {
            guard let data = try SynchronizableStore.get(account: Self.cloudConfigAccount) else { return nil }
            configSyncError = nil
            return try JSONDecoder().decode(ConfigExport.self, from: data)
        } catch {
            configSyncError = "iCloud Keychain sync failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func receiveCloudConfig() {
        guard cloudSyncEnabled, let config = cloudConfig() else { return }
        applyingConfig = true
        hosts = config.hosts
        vncHosts = config.vncHosts
        snippets = config.snippets
        toolbarKeys = config.toolbarKeys
        if let workspace = config.workspace {
            applyWorkspace(WorkspaceConfig.merged(local: localWorkspace, remote: workspace))
        }
        try? knownHosts.merge(config.knownHosts)
        applyingConfig = false
    }

    func saveConfigToCloud() {
        guard cloudSyncEnabled, !applyingConfig,
            let data = try? JSONEncoder().encode(exportConfig())
        else { return }
        do {
            try SynchronizableStore.set(data, account: Self.cloudConfigAccount)
            configSyncError = nil
        } catch {
            configSyncError = "iCloud Keychain sync failed: \(error.localizedDescription)"
        }
    }

    func tmuxSessions(for host: HostConfig) -> [String] {
        localWorkspace.tmuxSessions(hostID: host.id, configuredSession: host.tmuxSession)
    }

    private var localWorkspace: WorkspaceConfig {
        WorkspaceConfig(
            savedTabs: savedTabs,
            sessionOrder: sessionOrder,
            updatedAtByHost: workspaceUpdatedAt
        )
    }

    private func applyWorkspace(_ workspace: WorkspaceConfig) {
        workspaceUpdatedAt = workspace.updatedAtByHost ?? [:]
        workspaceUpdatedAtStore.save(workspaceUpdatedAt)
        savedTabs = workspace.savedTabs
        sessionOrder = workspace.sessionOrder
    }

    private func markWorkspaceChanged<T: Equatable>(old: [String: T], new: [String: T]) {
        guard !applyingConfig else { return }
        let changed = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
        guard !changed.isEmpty else { return }
        let now = Date()
        for hostID in changed {
            workspaceUpdatedAt[hostID] = now
        }
        workspaceUpdatedAtStore.save(workspaceUpdatedAt)
    }

    func setCredentialsSyncEnabled(_ enabled: Bool) {
        guard enabled, cloudSyncEnabled else { return }
        var credentials = localCredentials()
        if let remote = cloudCredentials() {
            credentials = mergedCredentials(local: credentials, remote: remote)
        }
        if credentials.deviceKey == nil {
            guard let deviceKey = createSharedDeviceKey() else { return }
            credentials.deviceKey = deviceKey
        }
        guard applyCredentials(credentials) else { return }
        saveCredentialsToCloud()
    }

    func saveCredentialsToCloud() {
        guard credentialsSyncEnabled, !applyingCredentials,
            let data = try? JSONEncoder().encode(localCredentials())
        else { return }
        do {
            try SynchronizableStore.set(data, account: Self.cloudCredentialsAccount)
            configSyncError = nil
        } catch {
            configSyncError = "iCloud Keychain sync failed: \(error.localizedDescription)"
        }
    }

    private func cloudCredentials() -> SyncedCredentials? {
        do {
            guard let data = try SynchronizableStore.get(account: Self.cloudCredentialsAccount) else { return nil }
            configSyncError = nil
            return try JSONDecoder().decode(SyncedCredentials.self, from: data)
        } catch {
            configSyncError = "iCloud Keychain sync failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func receiveCloudCredentials() {
        guard let credentials = cloudCredentials() else { return }
        applyCredentials(credentials)
    }

    private func localCredentials() -> SyncedCredentials {
        let deviceKey = (try? keyStore.load(tag: Self.deviceKeyTag)).flatMap(PortablePrivateKey.init)
        let keys = importedKeys.reduce(into: [String: PortablePrivateKey]()) { result, key in
            guard let material = try? keyStore.load(tag: key.tag),
                let portable = PortablePrivateKey(material)
            else { return }
            result[key.tag] = portable
        }
        let passwords = vncHosts.reduce(into: [String: String]()) { result, host in
            let account = "vnc-\(host.id.uuidString)"
            if let password = PasswordVault.get(account: account) {
                result[account] = password
            }
        }
        return SyncedCredentials(
            deviceKey: deviceKey,
            importedKeys: importedKeys,
            privateKeys: keys,
            vncPasswords: passwords
        )
    }

    private func mergedCredentials(local: SyncedCredentials, remote: SyncedCredentials) -> SyncedCredentials {
        var privateKeys = local.privateKeys
        privateKeys.merge(remote.privateKeys) { _, remote in remote }
        var passwords = local.vncPasswords
        passwords.merge(remote.vncPasswords) { _, remote in remote }
        return SyncedCredentials(
            deviceKey: PortablePrivateKey.stablePreferred(local.deviceKey, remote.deviceKey),
            importedKeys: ConfigExport.mergeByID(existing: local.importedKeys, incoming: remote.importedKeys),
            privateKeys: privateKeys,
            vncPasswords: passwords
        )
    }

    @discardableResult
    private func applyCredentials(_ credentials: SyncedCredentials) -> Bool {
        applyingCredentials = true
        var deviceKeyRestored = true
        if let deviceKey = credentials.deviceKey {
            do {
                let material = try deviceKey.keyMaterial()
                if try keyStore.load(tag: Self.deviceKeyTag)?.publicKeyRawRepresentation
                    != material.publicKeyRawRepresentation
                {
                    try keyStore.saveImported(tag: Self.deviceKeyTag, key: material)
                }
                cachedKey = material
            } catch {
                configSyncError = "Couldn't restore synced device key: \(error.localizedDescription)"
                deviceKeyRestored = false
            }
        }
        let removedTags = Set(importedKeys.map(\.tag)).subtracting(credentials.importedKeys.map(\.tag))
        for tag in removedTags {
            try? keyStore.delete(tag: tag)
        }
        for (tag, key) in credentials.privateKeys {
            do {
                try keyStore.saveImported(tag: tag, key: key.keyMaterial())
            } catch {
                configSyncError = "Couldn't restore synced SSH key: \(error.localizedDescription)"
            }
        }
        importedKeys = credentials.importedKeys
        for host in vncHosts {
            let account = "vnc-\(host.id.uuidString)"
            if let password = credentials.vncPasswords[account] {
                PasswordVault.set(password, account: account)
            } else {
                PasswordVault.delete(account: account)
            }
        }
        applyingCredentials = false
        return deviceKeyRestored
    }

    private func createSharedDeviceKey() -> PortablePrivateKey? {
        let material = DeviceKeyMaterial.software(P256.Signing.PrivateKey())
        guard let portable = PortablePrivateKey(material) else { return nil }
        do {
            try keyStore.saveImported(tag: Self.deviceKeyTag, key: material)
            cachedKey = material
            return portable
        } catch {
            configSyncError = "Couldn't create shared device key: \(error.localizedDescription)"
            return nil
        }
    }

    func setVNCPassword(_ password: String, for host: VNCHostConfig) {
        PasswordVault.set(password, account: "vnc-\(host.id.uuidString)")
        saveCredentialsToCloud()
    }

    func vncPassword(for host: VNCHostConfig) -> String {
        PasswordVault.get(account: "vnc-\(host.id.uuidString)") ?? ""
    }

    func deleteVNCHost(_ host: VNCHostConfig) {
        PasswordVault.delete(account: "vnc-\(host.id.uuidString)")
        vncHosts.removeAll { $0.id == host.id }
        saveCredentialsToCloud()
    }
}
