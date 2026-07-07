import Foundation

public struct ImportedKey: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var tag: String
    public var publicKeyLine: String

    public init(id: UUID = UUID(), name: String, tag: String, publicKeyLine: String) {
        self.id = id
        self.name = name
        self.tag = tag
        self.publicKeyLine = publicKeyLine
    }
}
