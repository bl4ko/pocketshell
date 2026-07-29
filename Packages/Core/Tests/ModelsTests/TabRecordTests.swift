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
