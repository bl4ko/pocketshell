import Foundation
import Testing

@testable import VoiceKit

@Test func chunkerSpeaksWholeSentencesAsTheyStream() {
    var chunker = SpeechChunker()
    #expect(chunker.append("Hmm, let me ").isEmpty)
    #expect(chunker.append("check that. Claude is") == ["Hmm, let me check that."])
    #expect(chunker.append(" busy, e.g. running tests! Ok") == ["Claude is busy, e.g. running tests!"])
    #expect(chunker.flush() == ["Ok"])
    #expect(chunker.flush().isEmpty)
}

@Test func chunkerDropsMarkdownAndCode() {
    var chunker = SpeechChunker()
    let spoken = chunker.append(
        "## Result\n**Done**: see [the PR](https://example.test/pr/1).\n```swift\nlet x = 1\n```\nAll good. ")
    #expect(spoken == ["Result", "Done: see the PR.", "All good."])
    #expect(SpeechChunker.clean("- run `make test` at https://example.test") == "run make test at a link")
    #expect(SpeechChunker.clean("```\ncode only\n```").isEmpty)
    #expect(SpeechChunker.clean("Done.\n---\nNext") == "Done. Next")
}

@Test func chunkerHoldsAnOpenCodeFence() {
    var chunker = SpeechChunker()
    #expect(chunker.append("```\nrm -rf build.\n").isEmpty)
    #expect(chunker.append("```\nDone. ") == ["Done."])
}

@Test func cleanerEmitsWholeWordsAsTokensArrive() {
    var cleaner = SpeechCleaner()
    #expect(cleaner.append("Hmm, le") == "Hmm, ")
    #expect(cleaner.append("t me che") == "let me ")
    #expect(cleaner.append("ck.").isEmpty)
    #expect(cleaner.held == "check.")
    #expect(cleaner.flush() == "check.")
    #expect(cleaner.flush().isEmpty)
}

@Test func cleanerDropsMarkdownCodeAndLinksAtAnyTokenSize() {
    let raw =
        "## Result\n**Done**: see [the PR](https://example.test/pr/1) or https://example.test/x now.\n"
        + "```swift\nlet x = 1\n```\n- run `make test`\n1. All good."
    for size in [1, 3, 7, 1000] {
        var cleaner = SpeechCleaner()
        var spoken = ""
        var rest = Substring(raw)
        while !rest.isEmpty {
            spoken += cleaner.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        spoken += cleaner.flush()
        #expect(spoken == "Result Done: see the PR or a link now. run make test All good.", "token size \(size)")
    }
}

@Test func cleanerHoldsAnOpenCodeFenceAndDropsItAtTheEnd() {
    var cleaner = SpeechCleaner()
    #expect(cleaner.append("Here it is:\n```\nrm -rf build.\n") == "Here it is: ")
    #expect(cleaner.flush().isEmpty)
    #expect(cleaner.append("[not a link] stays ") == "[not a link] stays ")
}
