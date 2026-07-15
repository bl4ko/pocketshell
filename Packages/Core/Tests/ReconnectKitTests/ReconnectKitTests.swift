import Testing

@testable import ReconnectKit

@Test func startsIdle() {
    let machine = ReconnectMachine()
    #expect(machine.state == .idle)
}

@Test func userConnectStartsConnecting() {
    var machine = ReconnectMachine()
    let action = machine.handle(.userConnect)
    #expect(action == .connect)
    #expect(machine.state == .connecting(failures: 0))
}

@Test func establishedMovesToConnected() {
    var machine = ReconnectMachine()
    _ = machine.handle(.userConnect)
    let action = machine.handle(.established)
    #expect(action == .none)
    #expect(machine.state == .connected)
}

@Test func connectionLostSchedulesRetryWithBaseDelay() {
    var machine = ReconnectMachine()
    _ = machine.handle(.userConnect)
    _ = machine.handle(.established)
    let action = machine.handle(.connectionLost)
    #expect(action == .scheduleRetry(after: .seconds(1)))
    #expect(machine.state == .waitingToReconnect(failures: 1, delay: .seconds(1)))
}

@Test func repeatedFailuresDoubleDelayUpToCap() {
    var machine = ReconnectMachine()
    _ = machine.handle(.userConnect)
    _ = machine.handle(.established)
    _ = machine.handle(.connectionLost)
    var delays: [Duration] = []
    for _ in 0..<6 {
        _ = machine.handle(.retryTimerFired)
        if case .scheduleRetry(let after) = machine.handle(.connectFailed) {
            delays.append(after)
        }
    }
    #expect(delays == [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
}

@Test func establishedResetsBackoff() {
    var machine = ReconnectMachine()
    _ = machine.handle(.userConnect)
    _ = machine.handle(.established)
    _ = machine.handle(.connectionLost)
    _ = machine.handle(.retryTimerFired)
    _ = machine.handle(.connectFailed)
    _ = machine.handle(.retryTimerFired)
    _ = machine.handle(.established)
    let action = machine.handle(.connectionLost)
    #expect(action == .scheduleRetry(after: .seconds(1)))
}

@Test func retryTimerFiredConnects() {
    var machine = ReconnectMachine()
    _ = machine.handle(.userConnect)
    _ = machine.handle(.established)
    _ = machine.handle(.connectionLost)
    let action = machine.handle(.retryTimerFired)
    #expect(action == .connect)
    #expect(machine.state == .connecting(failures: 1))
}

@Test func pathChangedWhileWaitingReconnectsImmediately() {
    var machine = ReconnectMachine()
    _ = machine.handle(.userConnect)
    _ = machine.handle(.established)
    _ = machine.handle(.connectionLost)
    let action = machine.handle(.pathChanged)
    #expect(action == .connect)
    #expect(machine.state == .connecting(failures: 1))
}

@Test func appForegroundedWhileWaitingReconnectsImmediately() {
    var machine = ReconnectMachine()
    _ = machine.handle(.userConnect)
    _ = machine.handle(.established)
    _ = machine.handle(.connectionLost)
    let action = machine.handle(.appForegrounded)
    #expect(action == .connect)
}

@Test func pathChangedWhileConnectedDoesNothing() {
    var machine = ReconnectMachine()
    _ = machine.handle(.userConnect)
    _ = machine.handle(.established)
    let action = machine.handle(.pathChanged)
    #expect(action == .none)
    #expect(machine.state == .connected)
}

@Test func userDisconnectFromConnectedDisconnects() {
    var machine = ReconnectMachine()
    _ = machine.handle(.userConnect)
    _ = machine.handle(.established)
    let action = machine.handle(.userDisconnect)
    #expect(action == .disconnect)
    #expect(machine.state == .idle)
}

@Test func userDisconnectWhileWaitingCancelsRetry() {
    var machine = ReconnectMachine()
    _ = machine.handle(.userConnect)
    _ = machine.handle(.established)
    _ = machine.handle(.connectionLost)
    let action = machine.handle(.userDisconnect)
    #expect(action == .cancelRetry)
    #expect(machine.state == .idle)
}

@Test func connectionLostWhileIdleDoesNothing() {
    var machine = ReconnectMachine()
    let action = machine.handle(.connectionLost)
    #expect(action == .none)
    #expect(machine.state == .idle)
}

@Test func connectFailedDuringInitialConnectSchedulesRetry() {
    var machine = ReconnectMachine()
    _ = machine.handle(.userConnect)
    let action = machine.handle(.connectFailed)
    #expect(action == .scheduleRetry(after: .seconds(1)))
    #expect(machine.state == .waitingToReconnect(failures: 1, delay: .seconds(1)))
}
