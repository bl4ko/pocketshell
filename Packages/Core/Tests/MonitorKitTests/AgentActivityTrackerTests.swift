import MonitorKit
import Testing
import TmuxKit

private func sample(_ key: String, _ title: String, _ status: AgentStatus) -> AgentActivityTracker.Sample {
    AgentActivityTracker.Sample(key: key, title: title, status: status)
}

@Test func firstObservationEmitsNothing() {
    var tracker = AgentActivityTracker()
    let events = tracker.update([sample("a", "w0", .idle), sample("b", "w1", .busy)])
    #expect(events.isEmpty)
}

@Test func busyToIdleEmitsAfterTwoIdlePolls() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "claude:0", .busy)])
    #expect(tracker.update([sample("a", "claude:0", .idle)]).isEmpty)
    let events = tracker.update([sample("a", "claude:0", .idle)])
    #expect(events == [AgentActivityTracker.Transition(key: "a", title: "claude:0", status: .idle)])
}

@Test func busyToWaitingEmitsAfterTwoWaitingPolls() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "w", .busy)])
    _ = tracker.update([sample("a", "w", .waiting)])
    let events = tracker.update([sample("a", "w", .waiting)])
    #expect(events == [AgentActivityTracker.Transition(key: "a", title: "w", status: .waiting)])
}

@Test func singlePollIdleBlipSuppressed() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "w", .busy)])
    _ = tracker.update([sample("a", "w", .idle)])
    _ = tracker.update([sample("a", "w", .busy)])
    let events = tracker.update([sample("a", "w", .busy)])
    #expect(events.isEmpty)
}

@Test func singlePollBusyBlipDoesNotArm() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "w", .idle)])
    _ = tracker.update([sample("a", "w", .busy)])
    _ = tracker.update([sample("a", "w", .idle)])
    let events = tracker.update([sample("a", "w", .idle)])
    #expect(events.isEmpty)
}

@Test func flappingEmitsOnlyOneTransition() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "w", .busy)])
    _ = tracker.update([sample("a", "w", .idle)])
    let first = tracker.update([sample("a", "w", .idle)])
    #expect(first.count == 1)
    #expect(tracker.update([sample("a", "w", .idle)]).isEmpty)
    #expect(tracker.update([sample("a", "w", .idle)]).isEmpty)
}

@Test func idleToBusyEmitsNothing() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "w", .idle)])
    _ = tracker.update([sample("a", "w", .busy)])
    let events = tracker.update([sample("a", "w", .busy)])
    #expect(events.isEmpty)
}

@Test func steadyBusyEmitsNothing() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "w", .busy)])
    let events = tracker.update([sample("a", "w", .busy)])
    #expect(events.isEmpty)
}

@Test func disappearedWindowIsForgotten() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "w", .busy)])
    _ = tracker.update([])
    _ = tracker.update([sample("a", "w", .idle)])
    let events = tracker.update([sample("a", "w", .idle)])
    #expect(events.isEmpty)
}

@Test func multipleTransitionsInOneUpdate() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "w0", .busy), sample("b", "w1", .busy)])
    _ = tracker.update([sample("a", "w0", .idle), sample("b", "w1", .waiting)])
    let events = tracker.update([sample("a", "w0", .idle), sample("b", "w1", .waiting)])
    #expect(events.count == 2)
}
