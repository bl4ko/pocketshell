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

public enum HerdrCompatibility: Equatable, Sendable {
    case compatible
    case liveHandoff(command: String)
    case restartRequired(command: String)
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

    public static func clientStatusCommand(session: String) -> String {
        "\(commandPrefix(session: session)) status client --json"
    }

    public static func serverStatusCommand(session: String) -> String {
        "\(commandPrefix(session: session)) status server --json"
    }

    public static func compatibility(clientOutput: String, serverOutput: String, session: String) -> HerdrCompatibility
    {
        guard let client = decode(ClientStatus.self, from: clientOutput),
            let server = decode(ServerStatus.self, from: serverOutput), server.running,
            let serverProtocol = server.protocolVersion, serverProtocol != client.protocolVersion
        else { return .compatible }
        guard server.capabilities?.liveHandoff == true else {
            return .restartRequired(command: restartCommand(session: session))
        }
        return .liveHandoff(
            command:
                "\(commandPrefix(session: session)) server live-handoff --import-exe \(shellQuote(client.binary)) --expected-protocol \(client.protocolVersion) --expected-version \(shellQuote(client.version))"
        )
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

    static func commandPrefix(session: String) -> String {
        session == "default" ? executable : "\(executable) --session \(shellQuote(session))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func restartCommand(session: String) -> String {
        session == "default" ? "herdr server stop" : "herdr session stop \(shellQuote(session))"
    }

    private static func decode<T: Decodable>(_ type: T.Type, from output: String) -> T? {
        guard let data = output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

private struct ClientStatus: Decodable {
    var version: String
    var protocolVersion: Int
    var binary: String

    enum CodingKeys: String, CodingKey {
        case version, binary
        case protocolVersion = "protocol"
    }
}

private struct ServerStatus: Decodable {
    struct Capabilities: Decodable {
        var liveHandoff: Bool

        enum CodingKeys: String, CodingKey {
            case liveHandoff = "live_handoff"
        }
    }

    var running: Bool
    var protocolVersion: Int?
    var capabilities: Capabilities?

    enum CodingKeys: String, CodingKey {
        case running, capabilities
        case protocolVersion = "protocol"
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
