import Testing

@testable import BrainKit

@Test func transcriptKeepsSpokenTurnsInOrder() {
    let lines = Transcript.lines([
        .system("You are a voice."),
        .user("How is the build?"),
        .assistant("", toolCalls: [ToolCall(id: "c1", name: "list_agents", arguments: "{}")]),
        .tool("c1", #"{"agents":[]}"#),
        .assistant("**Claude** finished.\nAll `tests` pass."),
        .user("Thanks"),
    ])
    #expect(
        lines == [
            TranscriptLine(id: 0, speaker: .user, text: "How is the build?"),
            TranscriptLine(id: 1, speaker: .assistant, text: "Claude finished. All tests pass."),
            TranscriptLine(id: 2, speaker: .user, text: "Thanks"),
        ])
}

@Test func transcriptHidesAppNotes() {
    let lines = Transcript.lines([
        .user("[app: Voice mode started. Claude has an unsent prompt in its input box: «fix it».]"),
        .assistant(
            "Claude has a draft. Want me to send it?", toolCalls: [ToolCall(id: "c2", name: "x", arguments: "")]),
        .tool("c2", "ok"),
        .user("Yes, send it\n\n[app: The user confirmed \"Send it?\". The action ran. Result: sent]"),
        .user("  \n"),
        .assistant("```\ncode only\n```"),
    ])
    #expect(lines.map(\.text) == ["Claude has a draft. Want me to send it?", "Yes, send it"])
    #expect(lines.map(\.speaker) == [.assistant, .user])
    #expect(lines.map(\.id) == [0, 1])
}

@Test func transcriptLeavesTheLiveCaptionToTheCaptionRow() {
    let messages: [ChatMessage] = [.user("Status?"), .assistant("All **good**.")]
    #expect(Transcript.lines(messages, live: "All good.").map(\.text) == ["Status?"])
    #expect(Transcript.lines(messages, live: "Listening…").map(\.text) == ["Status?", "All good."])
    #expect(Transcript.lines([.user("Status?")], live: "Status?").isEmpty)
    #expect(Transcript.lines([], live: "Status?").isEmpty)
}
