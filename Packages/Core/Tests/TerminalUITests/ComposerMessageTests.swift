import Testing

@testable import TerminalUI

struct ComposerMessageTests {
    @Test func wrapsInBracketedPasteAndSubmits() {
        let payload = ComposerMessage.payload("fix the tests", bracketedPaste: true)
        #expect(payload == "\u{1b}[200~fix the tests\u{1b}[201~\r")
    }

    @Test func sendsPlainTextWhenBracketedPasteIsOff() {
        #expect(ComposerMessage.payload("ls", bracketedPaste: false) == "ls\r")
    }

    @Test func keepsAMultilinePromptInOneBlock() {
        let payload = ComposerMessage.payload("first\nsecond", bracketedPaste: true)
        #expect(payload == "\u{1b}[200~first\nsecond\u{1b}[201~\r")
    }

    @Test func normalizesCarriageReturns() {
        #expect(ComposerMessage.payload("a\r\nb\rc", bracketedPaste: false) == "a\nb\nc\r")
    }

    @Test func canSendWithoutSubmitting() {
        #expect(ComposerMessage.payload("draft", bracketedPaste: false, submit: false) == "draft")
    }

    @Test func emptyTextSendsNothing() {
        #expect(ComposerMessage.payload("", bracketedPaste: true) == "")
    }
}
