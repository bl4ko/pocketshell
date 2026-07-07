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

    private var previous: [String: AgentStatus] = [:]

    public init() {}

    public mutating func update(_ samples: [Sample]) -> [Transition] {
        var transitions: [Transition] = []
        var current: [String: AgentStatus] = [:]
        for sample in samples {
            current[sample.key] = sample.status
            if previous[sample.key] == .busy, sample.status != .busy {
                transitions.append(Transition(key: sample.key, title: sample.title, status: sample.status))
            }
        }
        previous = current
        return transitions
    }
}
