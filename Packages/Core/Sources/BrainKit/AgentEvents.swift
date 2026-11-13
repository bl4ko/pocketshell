import Foundation
import MonitorKit
import TmuxKit

public struct AgentEvent: Equatable, Sendable {
    public enum Kind: Int, Comparable, Sendable {
        case done = 0
        case waiting = 1

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let agentID: String
    public let name: String
    public let kind: Kind
    public let prompt: InteractivePrompt?

    public init(agentID: String, name: String, kind: Kind, prompt: InteractivePrompt? = nil) {
        self.agentID = agentID
        self.name = name
        self.kind = kind
        self.prompt = prompt
    }
}

public struct WaitingPrompt: Equatable, Sendable, Identifiable {
    public let agentID: String
    public let agentName: String
    public let prompt: InteractivePrompt

    public init(agentID: String, agentName: String, prompt: InteractivePrompt) {
        self.agentID = agentID
        self.agentName = agentName
        self.prompt = prompt
    }

    public var id: String { agentID + "|" + prompt.question }
}

public struct AgentEventQueue: Sendable {
    public private(set) var events: [AgentEvent] = []

    public init() {}

    public var isEmpty: Bool { events.isEmpty }
    public var hasPrompt: Bool { events.contains { $0.prompt != nil } }

    public mutating func push(_ event: AgentEvent) {
        events.removeAll { $0.agentID == event.agentID }
        events.append(event)
    }

    public mutating func remove(agentID: String) {
        events.removeAll { $0.agentID == agentID && $0.kind == .waiting }
    }

    public mutating func drainPrompts() -> String? {
        let waiting = events.filter { $0.kind == .waiting }
        guard let first = waiting.first(where: { $0.prompt != nil }), let prompt = first.prompt else { return nil }
        events.removeAll { $0.kind == .waiting }
        let others = waiting.filter { $0.agentID != first.agentID }.map(\.name)
        let lead = others.isEmpty ? "" : list(others) + (others.count == 1 ? " needs" : " need") + " your input too. "
        return lead + PromptSpeech.sentence(prompt, agent: first.name)
    }

    public mutating func drain() -> String? {
        defer { events.removeAll() }
        return Self.announcement(for: events)
    }

    public static func announcement(for events: [AgentEvent]) -> String? {
        let waiting = events.filter { $0.kind == .waiting }.map(\.name)
        let done = events.filter { $0.kind == .done }.map(\.name)
        var parts: [String] = []
        if !waiting.isEmpty {
            parts.append(list(waiting) + (waiting.count == 1 ? " needs your input" : " need your input"))
        }
        if !done.isEmpty {
            if waiting.count + done.count > 3, !waiting.isEmpty {
                parts.append("\(done.count) other \(done.count == 1 ? "agent" : "agents") finished")
            } else {
                parts.append(list(done) + " finished")
            }
        }
        guard !parts.isEmpty else { return nil }
        let sentence = parts.joined(separator: ", and ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }

    private func list(_ names: [String]) -> String { Self.list(names) }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        if names.count > 3 { return names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

public struct AgentEventDetector: Sendable {
    private var tracker = AgentActivityTracker()
    private var asked: [String: InteractivePrompt] = [:]

    public init() {}

    public mutating func update(_ agents: [BrainAgent]) -> [AgentEvent] {
        let samples = agents.map {
            AgentActivityTracker.Sample(key: $0.id, title: $0.spokenName, status: $0.activityStatus)
        }
        var events = tracker.update(samples).compactMap { transition -> AgentEvent? in
            let waiting = transition.status == .waiting
            if waiting, asked[transition.key] != nil { return nil }
            return AgentEvent(agentID: transition.key, name: transition.title, kind: waiting ? .waiting : .done)
        }
        var next: [String: InteractivePrompt] = [:]
        for agent in agents where agent.status == .waiting {
            guard let prompt = agent.prompt ?? asked[agent.id] else { continue }
            next[agent.id] = prompt
            guard asked[agent.id] != prompt else { continue }
            events.removeAll { $0.agentID == agent.id }
            events.append(AgentEvent(agentID: agent.id, name: agent.spokenName, kind: .waiting, prompt: prompt))
        }
        asked = next
        return events
    }
}

public enum PromptSpeech {
    public static func sentence(_ prompt: InteractivePrompt, agent: String) -> String {
        let (about, question) = spokenQuestion(prompt)
        var parts: [String]
        if let context = spokenContext(prompt) {
            parts = ["\(agent) asks for permission: \(context).", question]
        } else if let about {
            parts = ["\(agent) asks about \(about): \(question)"]
        } else {
            parts = ["\(agent) asks: \(question)"]
        }
        for option in prompt.choices.prefix(5) {
            parts.append("Option \(option.number), \(spokenLabel(option.label)).")
        }
        parts.append("Which one?")
        return parts.joined(separator: " ")
    }

    public static func summary(_ prompt: InteractivePrompt) -> String {
        let question =
            [prompt.header, prompt.context.isEmpty ? nil : prompt.context.joined(separator: " / ")]
            .compactMap { $0 }.map { $0 + ": " }.joined() + prompt.question
        let options = prompt.options.map { option in
            "\(option.number) \(option.label)" + (option.freeText ? " (free text)" : "")
        }
        return "asks «\(clip(question, 300))», options: " + options.joined(separator: "; ")
    }

    public static func spokenQuestion(_ prompt: InteractivePrompt) -> (about: String?, question: String) {
        let question = prompt.question
        guard question.count > 140 else { return (nil, question) }
        var sentences: [String] = []
        var sentence = ""
        for character in question {
            sentence.append(character)
            guard ".?!".contains(character) else { continue }
            sentences.append(sentence.trimmingCharacters(in: .whitespaces))
            sentence = ""
        }
        if !sentence.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(sentence.trimmingCharacters(in: .whitespaces))
        }
        guard let last = sentences.last(where: { $0.hasSuffix("?") }) ?? sentences.last else { return (nil, question) }
        return (prompt.header, last)
    }

    static func spokenContext(_ prompt: InteractivePrompt) -> String? {
        guard !prompt.context.isEmpty else { return nil }
        let lines = prompt.context.prefix(2).map { $0.hasPrefix("$ ") ? String($0.dropFirst(2)) : $0 }
        return clip(lines.joined(separator: ", "), 100)
    }

    static func spokenLabel(_ label: String) -> String {
        var text = label.replacing(/\s*\((?:esc|[a-z])\)$/, with: "")
        var recommended = false
        if let range = text.firstRange(of: /\s*\(recommended\)/.ignoresCase()) {
            text.removeSubrange(range)
            recommended = true
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return recommended ? text + ", recommended" : text
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
