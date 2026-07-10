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

struct TabRecord: Codable, Equatable {
    var name: String?
    var tmuxSession: String?
    var windowIndex: Int?
}

@MainActor
final class AppStore: ObservableObject {
    static let deviceKeyTag = "pocketshell-device-key"

    @Published var hosts: [HostConfig] { didSet { hostsStore.save(hosts) } }
    @Published var vncHosts: [VNCHostConfig] { didSet { vncHostsStore.save(vncHosts) } }
    @Published var snippets: [Snippet] { didSet { snippetsStore.save(snippets) } }
    @Published var toolbarKeys: [ToolbarKey] { didSet { toolbarStore.save(toolbarKeys) } }
    @Published var importedKeys: [ImportedKey] { didSet { importedKeysStore.save(importedKeys) } }
    @Published var savedTabs: [String: [TabRecord]] { didSet { savedTabsStore.save(savedTabs) } }
    @Published var sessionOrder: [String: [String]] { didSet { sessionOrderStore.save(sessionOrder) } }

    let keyStore = DeviceKeyStore()
    let knownHosts: KnownHostsStore

    private let hostsStore = JSONStore<[HostConfig]>(filename: "hosts.json")
    private let vncHostsStore = JSONStore<[VNCHostConfig]>(filename: "vnc-hosts.json")
    private let snippetsStore = JSONStore<[Snippet]>(filename: "snippets.json")
    private let toolbarStore = JSONStore<[ToolbarKey]>(filename: "toolbar.json")
    private let importedKeysStore = JSONStore<[ImportedKey]>(filename: "imported-keys.json")
    private let savedTabsStore = JSONStore<[String: [TabRecord]]>(filename: "tabs.json")
    private let sessionOrderStore = JSONStore<[String: [String]]>(filename: "session-order.json")

    init() {
        hosts = hostsStore.load() ?? []
        vncHosts = vncHostsStore.load() ?? []
        snippets = snippetsStore.load() ?? []
        toolbarKeys = toolbarStore.load() ?? ToolbarKey.defaults
        importedKeys = importedKeysStore.load() ?? []
        savedTabs = savedTabsStore.load() ?? [:]
        sessionOrder = sessionOrderStore.load() ?? [:]
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pocketshell", isDirectory: true)
        knownHosts = KnownHostsStore(fileURL: dir.appendingPathComponent("known-hosts.json"))
    }

    private var cachedKey: DeviceKeyMaterial?

    func deviceKey() throws -> DeviceKeyMaterial {
        if let cachedKey { return cachedKey }
        let key: DeviceKeyMaterial
        if let injected = ProcessInfo.processInfo.environment["PS_TEST_KEY"],
           let raw = Data(base64Encoded: injected) {
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
            knownHosts: knownHosts.entries()
        )
    }

    func applyConfig(_ config: ConfigExport) {
        hosts = ConfigExport.mergeByID(existing: hosts, incoming: config.hosts)
        vncHosts = ConfigExport.mergeByID(existing: vncHosts, incoming: config.vncHosts)
        snippets = ConfigExport.mergeByID(existing: snippets, incoming: config.snippets)
        toolbarKeys = ConfigExport.mergeByID(existing: toolbarKeys, incoming: config.toolbarKeys)
        try? knownHosts.merge(config.knownHosts)
    }

    func setVNCPassword(_ password: String, for host: VNCHostConfig) {
        PasswordVault.set(password, account: "vnc-\(host.id.uuidString)")
    }

    func vncPassword(for host: VNCHostConfig) -> String {
        PasswordVault.get(account: "vnc-\(host.id.uuidString)") ?? ""
    }

    func deleteVNCHost(_ host: VNCHostConfig) {
        PasswordVault.delete(account: "vnc-\(host.id.uuidString)")
        vncHosts.removeAll { $0.id == host.id }
    }
}
