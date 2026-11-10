public struct AudioRecovery: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case interruptionBegan
        case interruptionEnded
        case appActive
        case restarted(Bool)
    }

    public enum Action: Equatable, Sendable {
        case none
        case pause
        case restart
        case resumed
    }

    public private(set) var paused = false

    public init() {}

    public mutating func handle(_ event: Event, engineRunning: Bool) -> Action {
        switch event {
        case .interruptionBegan:
            guard !paused else { return .none }
            paused = true
            return .pause
        case .interruptionEnded, .appActive:
            return paused || !engineRunning ? .restart : .none
        case .restarted(true):
            guard paused else { return .none }
            paused = false
            return .resumed
        case .restarted(false):
            guard !paused else { return .none }
            paused = true
            return .pause
        }
    }
}
