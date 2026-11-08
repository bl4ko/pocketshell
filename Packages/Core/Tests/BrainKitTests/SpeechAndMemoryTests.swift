import Foundation
import Testing

@testable import BrainKit

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
}

@Test func chunkerHoldsAnOpenCodeFence() {
    var chunker = SpeechChunker()
    #expect(chunker.append("```\nrm -rf build.\n").isEmpty)
    #expect(chunker.append("```\nDone. ") == ["Done."])
}

@Test func conversationResumesOnlyWithinAnHour() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var conversation = Conversation(hostID: "h", now: start)
    conversation.append(.user("hello"), at: start)
    #expect(conversation.canResume(at: start.addingTimeInterval(59 * 60)))
    #expect(!conversation.canResume(at: start.addingTimeInterval(61 * 60)))
}

@Test func storeContinuesARecentConversationAndStartsFreshAfterExpiry() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brain-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConversationStore(directory: directory)
    let start = Date(timeIntervalSince1970: 2_000_000)
    var conversation = store.load(hostID: "host-1", now: start)
    conversation.append(.user("tell claude to run the tests"), at: start)
    conversation.append(.assistant("Sent."), at: start)
    store.save(conversation)
    #expect(store.load(hostID: "host-1", now: start.addingTimeInterval(1800)).messages.count == 2)
    #expect(store.load(hostID: "host-1", now: start.addingTimeInterval(3601)).messages.isEmpty)
    #expect(store.load(hostID: "host-2", now: start).messages.isEmpty)
}

@Test func historyTrimsWholeTurnsAndSummarizesTheDroppedRequests() {
    let now = Date()
    var conversation = Conversation(hostID: "h", now: now, maxMessages: 6, maxCharacters: 10_000)
    for turn in 1...5 {
        conversation.append(.user("request \(turn)"), at: now)
        conversation.append(
            .assistant("", toolCalls: [ToolCall(id: "c\(turn)", name: "list_agents", arguments: "{}")]), at: now)
        conversation.append(.tool("c\(turn)", "{}"), at: now)
        conversation.append(.assistant("answer \(turn)"), at: now)
    }
    #expect(conversation.messages.count <= 6)
    #expect(conversation.messages.first?.role == .user)
    #expect(conversation.messages.first?.content == "request 5")
    #expect(conversation.summary?.contains("request 1") == true)
    #expect(conversation.summary?.contains("request 4") == true)
    let request = conversation.request(system: "sys")
    #expect(request.first?.role == .system)
    #expect(request.first?.content?.contains("request 3") == true)
}

@Test func historyTruncatesHugeToolResults() {
    var conversation = Conversation(hostID: "h", now: Date())
    conversation.append(.tool("c", String(repeating: "x", count: 20000)), at: Date())
    #expect((conversation.messages.last?.content?.count ?? 0) < 6100)
}
