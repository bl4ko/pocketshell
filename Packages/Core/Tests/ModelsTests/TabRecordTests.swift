import Foundation
import Models
import Testing

@Test func tabNumberRoundTripsAndRemainsBackwardCompatible() throws {
    let record = TabRecord(tmuxSession: "agents", windowIndex: 2, number: 7)
    let decoded = try JSONDecoder().decode(TabRecord.self, from: JSONEncoder().encode(record))
    #expect(decoded.number == 7)

    let legacy = Data(#"{"tmuxSession":"agents","windowIndex":2}"#.utf8)
    #expect(try JSONDecoder().decode(TabRecord.self, from: legacy).number == nil)
}

@Test func preservingNamesKeepsLocalNamesWhenRemoteIsNil() {
    let local = [
        TabRecord(name: "homeassistant", tmuxSession: "homeops", windowIndex: 4, number: 9, windowName: "ha"),
        TabRecord(tmuxSession: "homeops", windowIndex: 0, number: 1, windowName: "claude-1"),
    ]
    let remote = [
        TabRecord(tmuxSession: "homeops", windowIndex: 4, number: 9),
        TabRecord(name: "renamed", tmuxSession: "homeops", windowIndex: 0, number: 1),
        TabRecord(tmuxSession: "homeops", windowIndex: 7, number: 2),
        TabRecord(number: 3),
    ]
    let merged = TabRecord.preservingNames(local: local, remote: remote)
    #expect(merged[0].name == "homeassistant")
    #expect(merged[0].windowName == "ha")
    #expect(merged[1].name == "renamed")
    #expect(merged[1].windowName == "claude-1")
    #expect(merged[2].name == nil)
    #expect(merged[3] == TabRecord(number: 3))
}
