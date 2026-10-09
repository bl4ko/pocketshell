import Foundation
import Testing

@testable import pocketshell

@MainActor
struct SessionMonitorKeyTests {
    @Test func windowKeyJoinsHostSessionAndIndex() {
        let id = UUID()
        #expect(SessionMonitor.windowKey(hostID: id, session: "main", windowIndex: 3) == "\(id):main:3")
    }
}
