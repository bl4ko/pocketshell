import Foundation

public struct VNCHostConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var group: String?

    public init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 5900,
        username: String = "",
        group: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.group = group
    }
}
