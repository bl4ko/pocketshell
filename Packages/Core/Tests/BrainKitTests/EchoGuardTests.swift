import Testing

@testable import BrainKit

@Test func wordsTheMouthJustSpokeAreEcho() {
    var echo = EchoGuard()
    for (index, piece) in ["Cla", "ude in ", "api is ", "busy run", "ning tests."].enumerated() {
        echo.heard(piece, at: 10 + Double(index) * 0.3)
    }
    #expect(echo.matches("in API is busy", since: 9))
    #expect(echo.matches("Claude", since: 10.2))
    #expect(!echo.matches("Claude", since: 11))
    #expect(echo.matches("running tests", since: 11))
    #expect(!echo.matches("is busy stop", since: 9))
    #expect(!echo.matches("wait", since: 9))
    #expect(!echo.matches("busy is", since: 9))
    #expect(!echo.matches("", since: 9))
}

@Test func onlyTheUnitInProgressCountsFromBeforeTheWindow() {
    var echo = EchoGuard()
    echo.heard("Should I send it now? ", at: 1)
    echo.heard("Claude in api is busy. ", at: 5)
    echo.heard("Codex is idle. ", at: 8)
    #expect(echo.matches("api is busy", since: 7))
    #expect(echo.matches("codex is idle", since: 7))
    #expect(!echo.matches("send it", since: 7))
}
