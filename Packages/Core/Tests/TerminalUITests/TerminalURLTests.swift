import Testing

@testable import TerminalUI

struct TerminalURLTests {
    @Test func findsTheLinkUnderTheTouch() {
        let lines = ["see https://github.com/bl4ko/pocketshell for details"]
        #expect(
            TerminalURL.find(lines: lines, wrapped: [false], row: 0, column: 10)
                == "https://github.com/bl4ko/pocketshell")
    }

    @Test func ignoresPlainWords() {
        #expect(TerminalURL.find(lines: ["just some output"], wrapped: [false], row: 0, column: 2) == nil)
    }

    @Test func joinsAWrappedLink() {
        let lines = ["open https://example.com/a/very", "/long/path now"]
        let found = TerminalURL.find(lines: lines, wrapped: [false, true], row: 1, column: 2)
        #expect(found == "https://example.com/a/very/long/path")
    }

    @Test func dropsTrailingPunctuation() {
        #expect(TerminalURL.url(in: "see https://example.com/x.", offset: 12) == "https://example.com/x")
    }
}
