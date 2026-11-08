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

    public init(agentID: String, name: String, kind: Kind) {
        self.agentID = agentID
        self.name = name
        self.kind = kind
    }
}

public struct AgentEventQueue: Sendable {
    public private(set) var events: [AgentEvent] = []

    public init() {}

    public var isEmpty: Bool { events.isEmpty }

    public mutating func push(_ event: AgentEvent) {
        events.removeAll { $0.agentID == event.agentID }
        events.append(event)
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

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        if names.count > 3 { return names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

public struct AgentEventDetector: Sendable {
    private var tracker = AgentActivityTracker()

    public init() {}

    public mutating func update(_ agents: [BrainAgent]) -> [AgentEvent] {
        let samples = agents.map {
            AgentActivityTracker.Sample(key: $0.id, title: $0.spokenName, status: $0.activityStatus)
        }
        return tracker.update(samples).map { transition in
            AgentEvent(
                agentID: transition.key, name: transition.title,
                kind: transition.status == .waiting ? .waiting : .done)
        }
    }
}
