import Foundation

public struct HerdrSession: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var isDefault: Bool
    public var running: Bool

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, running
        case isDefault = "default"
    }

    public init(name: String, isDefault: Bool, running: Bool) {
        self.name = name
        self.isDefault = isDefault
        self.running = running
    }
}

public enum HerdrAgentStatus: String, Codable, Equatable, Sendable {
    case idle
    case working
    case blocked
    case done
    case unknown

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}

public struct HerdrWorkspace: Codable, Equatable, Sendable, Identifiable {
    public var id: String { workspaceID }
    public var workspaceID: String
    public var number: Int
    public var label: String
    public var status: HerdrAgentStatus
    public var focused: Bool

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number, label, focused
        case status = "agent_status"
    }
}

public struct HerdrAgent: Codable, Equatable, Sendable, Identifiable {
    public var id: String { paneID }
    public var paneID: String
    public var workspaceID: String
    public var tabID: String
    public var agent: String?
    public var displayAgent: String?
    public var title: String?
    public var status: HerdrAgentStatus
    public var focused: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case agent, title, focused
        case displayAgent = "display_agent"
        case status = "agent_status"
    }
}

public struct HerdrSnapshot: Codable, Equatable, Sendable {
    public var version: String
    public var protocolVersion: Int
    public var focusedWorkspaceID: String?
    public var workspaces: [HerdrWorkspace]
    public var agents: [HerdrAgent]

    enum CodingKeys: String, CodingKey {
        case version, workspaces, agents
        case protocolVersion = "protocol"
        case focusedWorkspaceID = "focused_workspace_id"
    }
}

public enum Herdr {
    private static let executable = "PATH=\"$HOME/.local/bin:$PATH:/opt/homebrew/bin:/usr/local/bin\" herdr"

    public static func listSessionsCommand() -> String {
        "\(executable) session list --json"
    }

    public static func snapshotCommand(session: String) -> String {
        "\(commandPrefix(session: session)) api snapshot"
    }

    public static func attachCommand(session: String) -> String {
        commandPrefix(session: session)
    }

    public static func focusWorkspaceCommand(session: String, workspaceID: String) -> String {
        "\(commandPrefix(session: session)) workspace focus \(shellQuote(workspaceID))"
    }

    public static func parseSessions(_ output: String) -> [HerdrSession] {
        guard let data = output.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(SessionEnvelope.self, from: data)
        else { return [] }
        return envelope.sessions
    }

    public static func parseSnapshot(_ output: String) -> HerdrSnapshot? {
        guard let data = output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SnapshotEnvelope.self, from: data).result.snapshot
    }

    private static func commandPrefix(session: String) -> String {
        session == "default" ? executable : "\(executable) --session \(shellQuote(session))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private struct SessionEnvelope: Codable {
    var sessions: [HerdrSession]
}

private struct SnapshotEnvelope: Codable {
    struct Result: Codable {
        var snapshot: HerdrSnapshot
    }

    var result: Result
}
