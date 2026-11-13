import Foundation
import MonitorKit
import TmuxKit

@MainActor
public final class AgentToolbox {
    public struct IO {
        public var exec: @MainActor (String) async -> String?
        public var focus: @MainActor (BrainAgent) async -> Bool
        public var unsentPrompt: @MainActor (BrainAgent) async -> String?
        public var current: @MainActor () -> CurrentTarget?
        public var tmuxSession: @MainActor () -> String?
        public var sleep: @MainActor (Duration) async -> Void

        public init(
            exec: @escaping @MainActor (String) async -> String?,
            focus: @escaping @MainActor (BrainAgent) async -> Bool,
            unsentPrompt: @escaping @MainActor (BrainAgent) async -> String? = { _ in nil },
            current: @escaping @MainActor () -> CurrentTarget? = { nil },
            tmuxSession: @escaping @MainActor () -> String? = { nil },
            sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        ) {
            self.exec = exec
            self.focus = focus
            self.unsentPrompt = unsentPrompt
            self.current = current
            self.tmuxSession = tmuxSession
            self.sleep = sleep
        }
    }

    public private(set) var agents: [BrainAgent] = []
    public private(set) var listed = false
    public var gate = ConfirmationGate()
    public var onSent: ((BrainAgent, String) -> Void)?
    public var sessions: SessionToolbox?
    let io: IO

    public init(io: IO) {
        self.io = io
    }

    public var currentAgent: BrainAgent? { agents.first(where: \.isCurrent) }

    public static let snapshotPrefix = "[app: Agents now: "

    public var snapshot: String? {
        guard let agents = agentSnapshot else { return nil }
        return sessions?.snapshot.map { agents + "\n" + $0 } ?? agents
    }

    private var agentSnapshot: String? {
        guard listed else { return nil }
        guard !agents.isEmpty else { return Self.snapshotPrefix + "none.]" }
        let items = agents.map { agent in
            "\(agent.spokenName) (\(agent.status.rawValue), \(agent.where_)\(agent.isCurrent ? ", current tab" : "")"
                + (agent.prompt.map { ", " + PromptSpeech.summary($0) } ?? "") + ")"
        }
        return Self.snapshotPrefix + items.joined(separator: "; ") + ".]"
    }

    @discardableResult
    public func listAgents() async -> [BrainAgent]? {
        guard let output = await io.exec(HostAgents.listCommand()) else { return nil }
        agents = await readPrompts(HostAgents.parse(output, current: io.current()))
        listed = true
        sessions?.ingest(output, agents: agents)
        return agents
    }

    public func unsentPrompt(for agent: BrainAgent) async -> String? {
        let text = await io.unsentPrompt(agent)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    public func call(_ call: ToolCall) async -> String {
        let arguments = call.argumentObject
        let name = (arguments["agent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch call.name {
        case "list_agents":
            guard let agents = await listAgents() else { return Self.error("The host is not connected.") }
            return Self.json(["agents": agents.map(Self.summary)])
        case "read_answer":
            return await withAgent(name) { agent in
                await self.readAnswer(agent, full: arguments["which"] as? String == "full")
            }
        case "send_prompt":
            let text = (arguments["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return Self.error("text is empty") }
            return await withAgent(name) { await self.request(.sendPrompt(agentID: $0.id, text: text), agent: $0) }
        case "answer_question":
            let option = "\(arguments["option"] ?? "")"
            return await withAgent(name) { agent in
                let screen = await self.io.exec(AgentControl.screenCommand(agent))
                guard let digit = AgentControl.optionDigit(option, screen: screen) else {
                    return Self.error("No option matches \(option). Read the agent's screen options first.")
                }
                return await self.request(.answer(agentID: agent.id, digit: digit), agent: agent, screen: screen)
            }
        case "send_key":
            if let sessions, arguments["target"] != nil || AgentKey(rawValue: arguments["key"] as? String ?? "") == nil
            {
                return await settle(sessions.call(call) { await self.listAgents() })
            }
            guard let key = AgentKey(rawValue: arguments["key"] as? String ?? "") else {
                return Self.error("key must be esc, ctrl_c, or enter")
            }
            return await withAgent(name) { agent in
                let screen = await self.io.exec(AgentControl.screenCommand(agent))
                return await self.request(.key(agentID: agent.id, key: key), agent: agent, screen: screen)
            }
        case "focus_agent":
            return await withAgent(name) { await self.request(.focus(agentID: $0.id), agent: $0) }
        case "unsent_prompt":
            return await withAgent(name) { agent in
                guard let text = await self.unsentPrompt(for: agent) else {
                    return Self.json(["agent": agent.spokenName, "unsent": ""])
                }
                return Self.json(["agent": agent.spokenName, "unsent": text])
            }
        case "start_agent":
            let kind = AgentKind(rawValue: (arguments["kind"] as? String ?? "claude").lowercased()) ?? .claude
            let directory = (arguments["directory"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return await request(.start(kind: kind, directory: directory), agent: nil)
        case "close_agent":
            return await withAgent(name) { await self.request(.close(agentID: $0.id), agent: $0) }
        case "get_model":
            return await withAgent(name) { await self.model($0, request: nil) }
        case "set_model":
            let model = (arguments["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { return Self.error("model is empty") }
            return await withAgent(name) { await self.model($0, request: model) }
        default:
            guard let sessions, SessionToolbox.toolNames.contains(call.name) else {
                return Self.error("Unknown tool \(call.name)")
            }
            return await settle(sessions.call(call) { await self.listAgents() })
        }
    }

    public func perform(_ action: AgentAction) async -> String {
        if case .session(let sessionAction) = action {
            guard let sessions else { return Self.error("unreachable") }
            return await sessions.perform(sessionAction) { await self.listAgents() }
        }
        if case .start(let kind, let directory) = action {
            if let herdr = await sessions?.herdrStart(
                kind: kind, directory: directory, current: io.current(), hasTmux: io.tmuxSession() != nil,
                refresh: { await self.listAgents() })
            {
                return herdr
            }
            guard let session = io.tmuxSession() ?? agents.compactMap(Self.tmuxSession).first else {
                return Self.error("There is no tmux session to start an agent in.")
            }
            guard
                let output = await io.exec(
                    AgentControl.startCommand(kind: kind, tmuxSession: session, directory: directory))
            else { return Self.error("The host is not connected.") }
            return Self.json([
                "started": kind.displayName, "pane": output.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
        guard let id = Self.agentID(action), let agent = agents.first(where: { $0.id == id }) else {
            return Self.error("That agent is gone.")
        }
        let command: String
        var result: [String: Any] = ["agent": agent.spokenName]
        switch action {
        case .sendPrompt(_, let text):
            command = AgentControl.promptCommand(agent, text: text)
            result["sent"] = text
        case .answer(_, let digit):
            command = AgentControl.textCommand(agent, text: digit)
            result["answered"] = digit
        case .key(_, let key):
            command = AgentControl.keyCommand(agent, key: key)
            result["key"] = key.rawValue
        case .close:
            command = AgentControl.exitCommand(agent)
            result["closed"] = true
        case .focus:
            guard await io.focus(agent) else { return Self.error("Could not switch to \(agent.spokenName).") }
            result["focused"] = true
            return Self.json(result)
        case .start, .session:
            return Self.error("unreachable")
        }
        guard let raw = await io.exec(AgentControl.checked(command)) else {
            return Self.error("The host is not connected.")
        }
        let (output, status) = AgentControl.splitExit(raw)
        if status != 0 {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
            return Self.error("The command failed with status \(status). \(detail)")
        }
        if case .herdr = agent.location, let failure = AgentControl.herdrFailure(output) {
            return Self.error(failure)
        }
        if case .sendPrompt(_, let text) = action { onSent?(agent, text) }
        return Self.json(result)
    }

    private func request(_ action: AgentAction, agent: BrainAgent?, screen: String? = nil) async -> String {
        if let question = SafetyPolicy.question(for: action, agent: agent, screen: screen) {
            return hold(action, question: question)
        }
        return await perform(action)
    }

    private func hold(_ action: AgentAction, question: String) -> String {
        gate.hold(action, question: question)
        return Self.json([
            "status": "needs_confirmation", "question": question,
            "instruction": "Ask the user this question and wait. Do not call the tool again.",
        ])
    }

    private func settle(_ outcome: SessionToolbox.Outcome) -> String {
        switch outcome {
        case .done(let result): result
        case .confirm(let action, let question): hold(.session(action), question: question)
        }
    }

    private func withAgent(_ name: String?, _ body: (BrainAgent) async -> String) async -> String {
        if agents.isEmpty { await listAgents() }
        switch AgentResolver.resolve(name, in: agents) {
        case .found(let agent): return await body(agent)
        case .none:
            await listAgents()
            if case .found(let agent) = AgentResolver.resolve(name, in: agents) { return await body(agent) }
            return Self.error(
                "No agent matches \(name ?? "the current tab"). Agents: "
                    + (agents.isEmpty ? "none" : agents.map(\.spokenName).joined(separator: ", ")))
        case .ambiguous(let options):
            return Self.error("Which one? " + options.map(\.spokenName).joined(separator: ", "))
        }
    }

    private func readAnswer(_ agent: BrainAgent, full: Bool) async -> String {
        guard let output = await io.exec(AgentControl.transcriptCommand(agent)) else {
            return Self.error("The host is not connected.")
        }
        guard let answer = AgentTranscript.parse(kind: agent.kind, output: output) else {
            return Self.error("No transcript found for \(agent.spokenName).")
        }
        let text = (full ? answer.full : answer.last) ?? ""
        let limit = full ? 12000 : 6000
        return Self.json([
            "agent": agent.spokenName, "status": agent.status.rawValue,
            "prompt": String((answer.prompt ?? "").prefix(600)),
            "answer": text.count > limit ? "…" + String(text.suffix(limit)) : text,
        ])
    }

    static func summary(_ agent: BrainAgent) -> [String: Any] {
        var item: [String: Any] = [
            "agent": agent.spokenName, "id": agent.id, "kind": agent.kind.rawValue, "status": agent.status.rawValue,
            "where": agent.where_, "preview": agent.preview,
        ]
        if let cwd = agent.cwd { item["cwd"] = cwd }
        if agent.isCurrent { item["current"] = true }
        return item
    }

    static func agentID(_ action: AgentAction) -> String? {
        switch action {
        case .sendPrompt(let id, _), .answer(let id, _), .key(let id, _), .focus(let id), .close(let id): id
        case .start, .session: nil
        }
    }

    static func tmuxSession(_ agent: BrainAgent) -> String? {
        if case .tmux(let session, _, _, _) = agent.location { return session }
        return nil
    }

    nonisolated public static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated public static func error(_ message: String) -> String {
        json(["error": message])
    }

    nonisolated public static let definitions: [ToolDefinition] = [
        tool(
            "list_agents",
            "Refresh the agent list: status, working directory, and a short preview of each agent's screen.", [:]),
        tool(
            "read_answer", "Read an agent's last answer, or its full last turn, from its transcript.",
            ["agent": agentParameter, "which": .object(["type": "string", "enum": .array(["last", "full"])])]),
        tool(
            "send_prompt", "Type a prompt into an agent's input box and submit it.",
            ["agent": agentParameter, "text": .object(["type": "string", "description": "The exact prompt."])],
            required: ["text"]),
        tool(
            "answer_question",
            "Choose an option in a question, permission, or selection prompt the agent shows.",
            [
                "agent": agentParameter,
                "option": .object(["type": "string", "description": "Option number, or words from its label."]),
            ], required: ["option"]),
        tool(
            "send_key",
            "Press a key in an agent, or with target in any tab, window, or pane: esc cancels or interrupts, ctrl_c "
                + "interrupts, enter accepts, tab and arrows move, shift_tab cycles modes, ctrl_d ends input.",
            [
                "agent": agentParameter,
                "key": .object(["type": "string", "enum": .array(SessionKey.allCases.map { .string($0.rawValue) })]),
                "target": SessionToolbox.targetParameter,
            ],
            required: ["key"]),
        tool("focus_agent", "Show an agent on the phone screen.", ["agent": agentParameter]),
        tool(
            "unsent_prompt", "Read the text typed in an agent's input box that was not sent yet.",
            ["agent": agentParameter]),
        tool(
            "start_agent", "Start a new Claude or Codex session in a new tmux window.",
            [
                "kind": .object(["type": "string", "enum": .array(["claude", "codex"])]),
                "directory": .object(["type": "string", "description": "Working directory."]),
            ]),
        tool("close_agent", "Exit an agent session.", ["agent": agentParameter]),
        tool(
            "get_model", "Read which model an agent session uses now and the models its menu offers.",
            ["agent": agentParameter]),
        tool(
            "set_model",
            "Switch the model of a running agent session for this session only, through the agent's own model "
                + "menu. Works only when the agent is idle with an empty input box. The result says which model is "
                + "active now.",
            [
                "agent": agentParameter,
                "model": .object([
                    "type": "string",
                    "description": "The model as the user said it, for example sonnet, opus 5.5, or the fast one.",
                ]),
            ], required: ["model"]),
    ]

    nonisolated private static let agentParameter: JSONValue = .object([
        "type": "string",
        "description": "Agent name as the app lists it. Omit for the agent in the current tab.",
    ])

    nonisolated private static func tool(
        _ name: String, _ description: String, _ properties: [String: JSONValue], required: [String] = []
    ) -> ToolDefinition {
        ToolDefinition(
            name: name, description: description,
            parameters: .object([
                "type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
            ]))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

public enum AgentResolver {
    public enum Match: Equatable, Sendable {
        case found(BrainAgent)
        case none
        case ambiguous([BrainAgent])
    }

    public static func resolve(_ name: String?, in agents: [BrainAgent]) -> Match {
        let key = normalize(name ?? "")
        if key.isEmpty || ["current", "this", "this one", "the current one", "current tab", "it"].contains(key) {
            if let current = agents.first(where: \.isCurrent) { return .found(current) }
            return agents.count == 1 ? .found(agents[0]) : agents.isEmpty ? .none : .ambiguous(agents)
        }
        if let exact = agents.first(where: { $0.id == name }) { return .found(exact) }
        let scored = agents.map { (agent: $0, score: score(key, $0)) }.filter { $0.score > 0 }
        guard let best = scored.map(\.score).max() else { return .none }
        let top = scored.filter { $0.score == best }.map(\.agent)
        if top.count == 1 { return .found(top[0]) }
        if let current = top.first(where: \.isCurrent) { return .found(current) }
        return .ambiguous(top)
    }

    static func score(_ key: String, _ agent: BrainAgent) -> Int {
        let spoken = normalize(agent.spokenName)
        let name = normalize(agent.name)
        let folder = normalize(agent.cwd.map { ($0 as NSString).lastPathComponent } ?? "")
        if key == spoken || (!name.isEmpty && key == name) { return 100 }
        var score = 0
        let words = Set(key.split(separator: " ").map(String.init))
        if !name.isEmpty, key.contains(name) || name.contains(key) { score += 40 }
        if !folder.isEmpty, words.contains(folder) || key.contains(folder) { score += 30 }
        if words.contains(agent.kind.rawValue) { score += 20 }
        if case .tmux(_, let index, _, _) = agent.location,
            key.firstMatch(of: /(?:tab|window)\s+(\d+)/).map({ Int($0.1) == index }) == true
        {
            score += 50
        }
        return score
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
