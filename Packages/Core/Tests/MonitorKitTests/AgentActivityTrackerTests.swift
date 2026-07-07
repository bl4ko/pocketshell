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

@Test func busyToIdleEmitsTransition() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "claude:0", .busy)])
    let events = tracker.update([sample("a", "claude:0", .idle)])
    #expect(events == [AgentActivityTracker.Transition(key: "a", title: "claude:0", status: .idle)])
}

@Test func busyToWaitingEmitsTransition() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "w", .busy)])
    let events = tracker.update([sample("a", "w", .waiting)])
    #expect(events == [AgentActivityTracker.Transition(key: "a", title: "w", status: .waiting)])
}

@Test func idleToBusyEmitsNothing() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "w", .idle)])
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
    let events = tracker.update([sample("a", "w", .idle)])
    #expect(events.isEmpty)
}

@Test func multipleTransitionsInOneUpdate() {
    var tracker = AgentActivityTracker()
    _ = tracker.update([sample("a", "w0", .busy), sample("b", "w1", .busy)])
    let events = tracker.update([sample("a", "w0", .idle), sample("b", "w1", .waiting)])
    #expect(events.count == 2)
}
