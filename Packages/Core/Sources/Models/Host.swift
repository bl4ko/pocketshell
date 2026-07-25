import Foundation

public struct HostConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var keyTag: String
    public var tmuxSession: String?
    public var onConnectCommand: String?
    public var group: String?
    public var proxyJump: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        keyTag: String,
        tmuxSession: String? = nil,
        onConnectCommand: String? = nil,
        group: String? = nil,
        proxyJump: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.keyTag = keyTag
        self.tmuxSession = tmuxSession
        self.onConnectCommand = onConnectCommand
        self.group = group
        self.proxyJump = proxyJump
    }
}

extension HostConfig {
    /// Bastions to traverse before reaching `host`, outermost first.
    public static func jumpChain(to host: HostConfig, in hosts: [HostConfig]) -> [HostConfig] {
        var chain: [HostConfig] = []
        var visited: Set<UUID> = [host.id]
        var current = host
        while let next = current.proxyJump, !visited.contains(next) {
            guard let bastion = hosts.first(where: { $0.id == next }) else { break }
            visited.insert(next)
            chain.append(bastion)
            current = bastion
        }
        return chain.reversed()
    }
}
