import TmuxKit

public struct AgentActivityTracker: Sendable {
    public struct Sample: Equatable, Sendable {
        public let key: String
        public let title: String
        public let status: AgentStatus

        public init(key: String, title: String, status: AgentStatus) {
            self.key = key
            self.title = title
            self.status = status
        }
    }

    public struct Transition: Equatable, Sendable {
        public let key: String
        public let title: String
        public let status: AgentStatus

        public init(key: String, title: String, status: AgentStatus) {
            self.key = key
            self.title = title
            self.status = status
        }
    }

    private struct State {
        var confirmed: AgentStatus
        var lastRaw: AgentStatus
    }

    private var states: [String: State] = [:]

    public init() {}

    public mutating func update(_ samples: [Sample]) -> [Transition] {
        var transitions: [Transition] = []
        var next: [String: State] = [:]
        for sample in samples {
            guard var state = states[sample.key] else {
                next[sample.key] = State(confirmed: sample.status, lastRaw: sample.status)
                continue
            }
            if sample.status != state.confirmed, sample.status == state.lastRaw {
                if state.confirmed == .busy {
                    transitions.append(Transition(key: sample.key, title: sample.title, status: sample.status))
                }
                state.confirmed = sample.status
            }
            state.lastRaw = sample.status
            next[sample.key] = state
        }
        states = next
        return transitions
    }
}
