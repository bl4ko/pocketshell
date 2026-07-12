import MonitorKit
import Testing
import TmuxKit

private let busyScreen = """
✶ Crunching… (12s · esc to interrupt)
⏵⏵ auto mode on (shift+tab to cycle)
"""

private let idleScreen = """
❯
ctx: 7% used / 93% left
⏵⏵ auto mode on (shift+tab to cycle)
"""

private let waitingScreen = """
Do you want to proceed?
❯ 1. Yes
  2. No
⏵⏵ auto mode on (shift+tab to cycle)
"""

private let compactingTail = """
❯
ctx: 17% used / 83% left
⏵⏵ auto mode on (shift+tab to cycle)
Update available! Run: brew upgrade claude-code
"""

@Test func firstSampleUsesMarkerClassification() {
    var resolver = TabStatusResolver()
    #expect(resolver.resolve(key: "t1", text: busyScreen) == .busy)
    var resolver2 = TabStatusResolver()
    #expect(resolver2.resolve(key: "t1", text: idleScreen) == .idle)
}

@Test func frozenBusyFrameResolvesIdle() {
    var resolver = TabStatusResolver()
    _ = resolver.resolve(key: "t1", text: busyScreen)
    #expect(resolver.resolve(key: "t1", text: busyScreen) == .idle)
}

@Test func changingScreenWithAgentMarkersResolvesBusy() {
    var resolver = TabStatusResolver()
    _ = resolver.resolve(key: "t1", text: compactingTail)
    #expect(resolver.resolve(key: "t1", text: compactingTail + "\nprogress 64%") == .busy)
}

@Test func staticWaitingScreenResolvesWaiting() {
    var resolver = TabStatusResolver()
    _ = resolver.resolve(key: "t1", text: waitingScreen)
    #expect(resolver.resolve(key: "t1", text: waitingScreen) == .waiting)
}

@Test func nonAgentScreenResolvesNilEvenWhenChanging() {
    var resolver = TabStatusResolver()
    _ = resolver.resolve(key: "t1", text: "apollo@host:~$ ls")
    #expect(resolver.resolve(key: "t1", text: "apollo@host:~$ ls -la") == nil)
}

@Test func keysTrackIndependently() {
    var resolver = TabStatusResolver()
    _ = resolver.resolve(key: "t1", text: busyScreen)
    _ = resolver.resolve(key: "t2", text: idleScreen)
    #expect(resolver.resolve(key: "t1", text: busyScreen) == .idle)
    #expect(resolver.resolve(key: "t2", text: idleScreen + "\nnew output") == .busy)
}

@Test func forgetDropsState() {
    var resolver = TabStatusResolver()
    _ = resolver.resolve(key: "t1", text: busyScreen)
    resolver.forget(key: "t1")
    #expect(resolver.resolve(key: "t1", text: busyScreen) == .busy)
}
