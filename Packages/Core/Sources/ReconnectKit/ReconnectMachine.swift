public struct ReconnectMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case connecting(failures: Int)
        case connected
        case waitingToReconnect(failures: Int, delay: Duration)
    }

    public enum Event: Equatable, Sendable {
        case userConnect
        case established
        case connectFailed
        case connectionLost
        case retryTimerFired
        case pathChanged
        case appForegrounded
        case userDisconnect
    }

    public enum Action: Equatable, Sendable {
        case connect
        case scheduleRetry(after: Duration)
        case cancelRetry
        case disconnect
        case none
    }

    public private(set) var state: State
    private let baseDelay: Duration
    private let maxDelay: Duration

    public init(baseDelay: Duration = .seconds(1), maxDelay: Duration = .seconds(30)) {
        self.state = .idle
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public mutating func handle(_ event: Event) -> Action {
        switch (state, event) {
        case (.idle, .userConnect):
            state = .connecting(failures: 0)
            return .connect

        case (.connecting, .established):
            state = .connected
            return .none

        case (.connecting(let failures), .connectFailed),
            (.connecting(let failures), .connectionLost):
            return scheduleRetry(failures: failures + 1)

        case (.connected, .connectionLost):
            return scheduleRetry(failures: 1)

        case (.waitingToReconnect(let failures, _), .retryTimerFired),
            (.waitingToReconnect(let failures, _), .pathChanged),
            (.waitingToReconnect(let failures, _), .appForegrounded):
            state = .connecting(failures: failures)
            return .connect

        case (.connected, .userDisconnect):
            state = .idle
            return .disconnect

        case (.connecting, .userDisconnect):
            state = .idle
            return .disconnect

        case (.waitingToReconnect, .userDisconnect):
            state = .idle
            return .cancelRetry

        default:
            return .none
        }
    }

    private mutating func scheduleRetry(failures: Int) -> Action {
        var delay = baseDelay
        for _ in 1..<failures {
            delay *= 2
            if delay >= maxDelay { break }
        }
        if delay > maxDelay { delay = maxDelay }
        state = .waitingToReconnect(failures: failures, delay: delay)
        return .scheduleRetry(after: delay)
    }
}
