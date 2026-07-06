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

    public init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        keyTag: String,
        tmuxSession: String? = nil,
        onConnectCommand: String? = nil,
        group: String? = nil
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
    }
}
