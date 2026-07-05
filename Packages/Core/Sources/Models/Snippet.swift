import Foundation

public struct Snippet: Identifiable, Codable, Hashable, Sendable {
    public enum RunMode: String, Codable, Sendable {
        case typeIntoTerminal
        case execAndShowOutput
    }

    public var id: UUID
    public var name: String
    public var command: String
    public var hostID: UUID?
    public var runMode: RunMode
    public var sortOrder: Int

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        hostID: UUID? = nil,
        runMode: RunMode = .typeIntoTerminal,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.hostID = hostID
        self.runMode = runMode
        self.sortOrder = sortOrder
    }
}
