import Foundation
import Testing

@testable import BrainKit

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

@Test func historyTrimsToHalfSoThePromptPrefixStaysStableBetweenTrims() {
    let now = Date()
    var conversation = Conversation(hostID: "h", now: now, maxMessages: 8, maxCharacters: 10_000)
    for turn in 1...4 {
        conversation.append(.user("request \(turn)"), at: now)
        conversation.append(.assistant("answer \(turn)"), at: now)
    }
    #expect(conversation.messages.count == 8)
    conversation.append(.user("request 5"), at: now)
    #expect(conversation.messages.map(\.content) == ["request 4", "answer 4", "request 5"])
    let prefix = conversation.request(system: "sys")
    conversation.append(.assistant("answer 5"), at: now)
    conversation.append(.user("request 6"), at: now)
    #expect(Array(conversation.request(system: "sys").prefix(prefix.count)) == prefix)
}

@Test func historyCanCutAnAssistantMessageToWhatWasHeard() {
    let now = Date()
    var conversation = Conversation(hostID: "h", now: now)
    conversation.append(.user("hi"), at: now)
    conversation.append(
        .assistant("Let me look.", toolCalls: [ToolCall(id: "c1", name: "list_agents", arguments: "{}")]), at: now)
    conversation.append(.tool("c1", "{}"), at: now)
    conversation.append(.assistant("Claude is busy. Codex is idle."), at: now)
    conversation.setContent("Claude is…", at: 3)
    #expect(conversation.messages[3].content == "Claude is…")
    conversation.setContent(nil, at: 3)
    #expect(conversation.messages.count == 3)
    conversation.setContent(nil, at: 1)
    #expect(conversation.messages[1].content == nil)
    #expect(conversation.messages[1].toolCalls.count == 1)
    #expect(conversation.removeLast()?.role == .tool)
}
