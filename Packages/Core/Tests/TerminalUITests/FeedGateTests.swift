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

@Test func automaticWindowSizeRepliesAreSuppressed() {
    #expect(AutomaticReplyFilter.shouldSuppress(Data([0x1b, 0x5b] + Array("4;67;224t".utf8))))
    #expect(!AutomaticReplyFilter.shouldSuppress(Data([0x1b, 0x5b] + Array("12;40R".utf8))))
    #expect(!AutomaticReplyFilter.shouldSuppress(Data("ctrl+l".utf8)))
}

@Test func clipboardImageSourcesParseMacRepresentations() throws {
    #expect(
        ClipboardImageSource.parse(#"<img src="file:///tmp/Screenshot%202026.png">"#)
            == .file(try #require(URL(string: "file:///tmp/Screenshot%202026.png"))))
    #expect(ClipboardImageSource.parse("<img src=\"data:image/png;base64,aGk=\">") == .data(Data("hi".utf8)))
}
