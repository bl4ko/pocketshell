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

    public var switcherLabel: String {
        switch self {
        case .working: "busy"
        case .blocked: "needs input"
        case .done: "done"
        case .idle: "idle"
        case .unknown: "unknown"
        }
    }
}

public struct HerdrWorkspace: Codable, Equatable, Sendable, Identifiable {
    public var id: String { workspaceID }
    public var workspaceID: String
    public var number: Int
    public var label: String
    public var status: HerdrAgentStatus
    public var focused: Bool
    public var worktree: Worktree?

    public struct Worktree: Codable, Equatable, Sendable {
        public var isLinked: Bool

        enum CodingKeys: String, CodingKey {
            case isLinked = "is_linked_worktree"
        }
    }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number, label, focused, worktree
        case status = "agent_status"
    }
}

public struct HerdrAgent: Codable, Equatable, Sendable, Identifiable {
    public var id: String { paneID }
    public var paneID: String
    public var workspaceID: String
    public var tabID: String
    public var agent: String?
    public var name: String?
    public var displayAgent: String?
    public var title: String?
    public var status: HerdrAgentStatus
    public var focused: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case agent, name, title, focused
        case displayAgent = "display_agent"
        case status = "agent_status"
    }
}

public struct HerdrPane: Codable, Equatable, Sendable, Identifiable {
    public var id: String { paneID }
    public var paneID: String
    public var workspaceID: String
    public var tabID: String
    public var agent: String?
    public var label: String?
    public var cwd: String?
    public var foregroundCwd: String?
    public var status: HerdrAgentStatus
    public var focused: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case agent, label, cwd, focused
        case foregroundCwd = "foreground_cwd"
        case status = "agent_status"
    }
}

public struct HerdrLayout: Codable, Equatable, Sendable {
    public struct Pane: Codable, Equatable, Sendable {
        public var paneID: String

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
        }
    }

    public var tabID: String
    public var focusedPaneID: String?
    public var zoomed: Bool
    public var panes: [Pane]

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case focusedPaneID = "focused_pane_id"
        case zoomed, panes
    }
}

public struct HerdrTab: Codable, Equatable, Sendable, Identifiable {
    public var id: String { tabID }
    public var tabID: String
    public var workspaceID: String
    public var label: String
    public var number: Int?
    public var status: HerdrAgentStatus?
    public var paneCount: Int?

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case label, number
        case status = "agent_status"
        case paneCount = "pane_count"
    }

    public init(
        tabID: String, workspaceID: String, label: String, number: Int? = nil, status: HerdrAgentStatus? = nil,
        paneCount: Int? = nil
    ) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.label = label
        self.number = number
        self.status = status
        self.paneCount = paneCount
    }
}

public struct HerdrSnapshot: Codable, Equatable, Sendable {
    public var version: String
    public var protocolVersion: Int
    public var focusedWorkspaceID: String?
    public var focusedTabID: String?
    public var focusedPaneID: String?
    public var workspaces: [HerdrWorkspace]
    public var agents: [HerdrAgent]
    public var tabs: [HerdrTab]?
    public var panes: [HerdrPane]?
    public var layouts: [HerdrLayout]?

    enum CodingKeys: String, CodingKey {
        case version, workspaces, agents, tabs, panes, layouts
        case protocolVersion = "protocol"
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
    }
}

public enum HerdrCompatibility: Equatable, Sendable {
    case compatible
    case liveHandoff(command: String)
    case clientUpdateRequired(serverVersion: String)
    case restartRequired(command: String)
}

public enum Herdr {
    static let executable = "PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH:$HOME/.local/bin\" herdr"

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

    public static func updateCommand() -> String {
        "\(executable) update"
    }

    public static func compatibility(clientOutput: String, serverOutput: String, session: String) -> HerdrCompatibility
    {
        guard let client = decode(ClientStatus.self, from: clientOutput),
            let server = decode(ServerStatus.self, from: serverOutput), server.running,
            let serverProtocol = server.protocolVersion, serverProtocol != client.protocolVersion
        else { return .compatible }
        guard serverProtocol < client.protocolVersion else {
            return .clientUpdateRequired(serverVersion: server.version ?? "newer")
        }
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

    public static func focusTabCommand(session: String, tabID: String) -> String {
        "\(commandPrefix(session: session)) tab focus \(shellQuote(tabID))"
    }

    public static func focusAgentCommand(session: String, paneID: String, tabID: String) -> String {
        "\(commandPrefix(session: session)) agent focus \(shellQuote(paneID)) || \(focusTabCommand(session: session, tabID: tabID))"
    }

    public static func paneShellPIDCommand(session: String, paneID: String) -> String {
        "\(commandPrefix(session: session)) pane process-info --pane \(shellQuote(paneID))"
            + " | sed -n 's/.*\"shell_pid\":\\([0-9][0-9]*\\).*/\\1/p'"
    }

    public static func paneReadCommand(session: String, paneID: String) -> String {
        "\(commandPrefix(session: session)) pane read \(shellQuote(paneID)) --source visible --format ansi"
    }

    public static func parseFocusedPaneID(_ output: String) -> String? {
        decode(FocusEnvelope.self, from: output)?.result.snapshot.focusedPaneID
    }

    public static func nextAgentNeedingInput(in snapshot: HerdrSnapshot) -> HerdrAgent? {
        let workspaceRank = Dictionary(
            snapshot.workspaces.map { ($0.workspaceID, $0.number) }, uniquingKeysWith: { first, _ in first })
        let tabRank = Dictionary(
            (snapshot.tabs ?? []).enumerated().map { ($0.element.tabID, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        func rank(_ item: EnumeratedSequence<[HerdrAgent]>.Element) -> (Int, Int, Int) {
            (workspaceRank[item.element.workspaceID] ?? .max, tabRank[item.element.tabID] ?? .max, item.offset)
        }
        let ordered = snapshot.agents.enumerated().sorted { rank($0) < rank($1) }.map(\.element)
        let start = ordered.firstIndex(where: \.focused).map { $0 + 1 } ?? 0
        return (ordered[start...] + ordered[..<start]).first { $0.status == .blocked }
    }

    public static func tab(matching spoken: String, in tabs: [HerdrTab]) -> HerdrTab? {
        let key = matchKey(spoken)
        guard !key.isEmpty else { return nil }
        let keyed = tabs.map { (tab: $0, key: matchKey($0.label)) }
        if let exact = keyed.first(where: { $0.key == key }) { return exact.tab }
        guard key.count >= 3 else { return nil }
        if let part = keyed.filter({ $0.key.contains(key) }).min(by: { $0.key.count < $1.key.count }) {
            return part.tab
        }
        return
            keyed
            .map { (tab: $0.tab, distance: editDistance($0.key, key), limit: max(1, $0.key.count / 4)) }
            .filter { $0.distance <= $0.limit }
            .min { $0.distance < $1.distance }?.tab
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

    public static func commandPrefix(session: String) -> String {
        session == "default" ? executable : "\(executable) --session \(shellQuote(session))"
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func matchKey(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let b = Array(b)
        var row = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var next = [i + 1]
            for (j, cb) in b.enumerated() {
                next.append(min(row[j + 1] + 1, next[j] + 1, row[j] + (ca == cb ? 0 : 1)))
            }
            row = next
        }
        return row[b.count]
    }

    private static func restartCommand(session: String) -> String {
        session == "default" ? "herdr server stop" : "herdr session stop \(shellQuote(session))"
    }

    static func decode<T: Decodable>(_ type: T.Type, from output: String) -> T? {
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
    var version: String?
    var protocolVersion: Int?
    var capabilities: Capabilities?

    enum CodingKeys: String, CodingKey {
        case running, version, capabilities
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

private struct FocusEnvelope: Decodable {
    struct Result: Decodable {
        struct Snapshot: Decodable {
            var focusedPaneID: String?

            enum CodingKeys: String, CodingKey {
                case focusedPaneID = "focused_pane_id"
            }
        }

        var snapshot: Snapshot
    }

    var result: Result
}
