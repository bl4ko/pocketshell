import Foundation
import Testing

@testable import TerminalUI

@Test func liveGatePassesDataThrough() {
    var gate = FeedGate()
    #expect(gate.ingest(Data("abc".utf8)) == Data("abc".utf8))
    #expect(gate.drain() == nil)
}

@Test func pausedGateBuffersAndDrains() {
    var gate = FeedGate()
    _ = gate.setLive(false)
    #expect(gate.ingest(Data("ab".utf8)) == nil)
    #expect(gate.ingest(Data("cd".utf8)) == nil)
    #expect(gate.drain() == Data("abcd".utf8))
    #expect(gate.drain() == nil)
}

@Test func becomingLiveFlushesPending() {
    var gate = FeedGate()
    _ = gate.setLive(false)
    _ = gate.ingest(Data("xy".utf8))
    #expect(gate.setLive(true) == Data("xy".utf8))
    #expect(gate.ingest(Data("z".utf8)) == Data("z".utf8))
}

@Test func setLiveWithoutPendingReturnsNil() {
    var gate = FeedGate()
    #expect(gate.setLive(false) == nil)
    #expect(gate.setLive(true) == nil)
}

@Test func pausedGateStillBuffersAfterDrain() {
    var gate = FeedGate()
    _ = gate.setLive(false)
    _ = gate.ingest(Data("a".utf8))
    _ = gate.drain()
    #expect(gate.ingest(Data("b".utf8)) == nil)
    #expect(gate.drain() == Data("b".utf8))
}
