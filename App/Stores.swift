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

@MainActor
final class AppStore: ObservableObject {
    static let deviceKeyTag = "pocketshell-device-key"

    @Published var hosts: [HostConfig] { didSet { hostsStore.save(hosts) } }
    @Published var snippets: [Snippet] { didSet { snippetsStore.save(snippets) } }
    @Published var toolbarKeys: [ToolbarKey] { didSet { toolbarStore.save(toolbarKeys) } }

    let keyStore = DeviceKeyStore()
    let knownHosts: KnownHostsStore

    private let hostsStore = JSONStore<[HostConfig]>(filename: "hosts.json")
    private let snippetsStore = JSONStore<[Snippet]>(filename: "snippets.json")
    private let toolbarStore = JSONStore<[ToolbarKey]>(filename: "toolbar.json")

    init() {
        hosts = hostsStore.load() ?? []
        snippets = snippetsStore.load() ?? []
        toolbarKeys = toolbarStore.load() ?? ToolbarKey.defaults
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
}
