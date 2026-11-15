import Foundation
import Testing

@testable import BrainKit

private func output(_ name: String) throws -> String {
    "@@psh-file:/home/dev/transcript.jsonl@@\n" + (try fixture(name))
}

@Test func claudeTranscriptSplitsIntoTurnsAcrossACompactionAndSkipsToolNoise() throws {
    let turns = try #require(AgentTranscript.turns(kind: .claude, output: try output("claude-turns.jsonl")))
    #expect(
        turns.map(\.prompt) == [
            "Which tests are flaky?", "Why does the reconnect test fail?", "Fix the paste test with the clipboard stub",
            "Summarize what changed today",
        ])
    #expect(turns[1].answer.last == "It waits a fixed 2 seconds for the backoff timer instead of the injected clock.")
    #expect(turns[2].afterCompaction && !turns[1].afterCompaction && !turns[3].afterCompaction)
    #expect(
        turns[2].answer.full
            == "I'll stub the pasteboard first.\n\nThe paste test now uses the clipboard stub and passes.")
    #expect(turns[0].time == "2026-11-14T08:00:00.000Z")
    #expect(AgentTranscript.parse(kind: .claude, output: try output("claude-turns.jsonl"))?.prompt == turns[3].prompt)
}

@Test func claudeTranscriptAfterClearStartsWithTheNewSession() throws {
    let turns = try #require(AgentTranscript.turns(kind: .claude, output: try output("claude-transcript.jsonl")))
    #expect(turns.map(\.prompt) == ["Rename the user table column", "Now add a migration and run the tests"])
}

@Test func codexRolloutSplitsIntoTurnsAndKeepsTurnsBeforeACompaction() throws {
    let turns = try #require(AgentTranscript.turns(kind: .codex, output: try output("codex-turns.jsonl")))
    #expect(turns.map(\.prompt) == ["List the open issues", "Fix the login test", "Release notes for the login fix?"])
    #expect(turns[1].afterCompaction && !turns[2].afterCompaction)
    #expect(turns[1].answer.last == "The login test now waits for the session cookie.")
    #expect(turns[1].answer.full == "Looking at the login test.")
    #expect(turns.map(\.answer.last).first == "There are three open issues.")
}

@Test func transcriptCommandWidensItsWindowOnlyWhenAsked() {
    let narrow = AgentTranscript.command(kind: .claude, pid: 4101, rootCommand: nil, cwd: "/home/dev/src/api")
    let wide = AgentTranscript.command(kind: .claude, pid: 4101, rootCommand: nil, cwd: "/home/dev/src/api", wide: true)
    #expect(narrow.hasSuffix("'1500' '600000'"))
    #expect(wide.hasSuffix("'20000' '1500000'"))
}

@MainActor
private final class TranscriptPane {
    var fixtureName: String
    var commands: [String] = []

    init(_ fixtureName: String) {
        self.fixtureName = fixtureName
    }

    func exec(_ command: String) -> String? {
        commands.append(command)
        if command.contains("list-panes") { return (try? fixture("list-agents.txt")) ?? "" }
        return "@@psh-file:/home/dev/transcript.jsonl@@\n" + ((try? fixture(fixtureName)) ?? "")
    }
}

@MainActor
private func read(_ pane: TranscriptPane, _ arguments: String) async throws -> [String: Any] {
    let box = AgentToolbox(io: .init(exec: { pane.exec($0) }, focus: { _ in true }, sleep: { _ in }))
    let result = await box.call(ToolCall(id: "1", name: "read_answer", arguments: arguments))
    return try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
}

@MainActor
@Test func readAnswerReadsTheTurnBeforeTheLatest() async throws {
    let pane = TranscriptPane("claude-turns.jsonl")
    let latest = try await read(pane, #"{"agent":"api"}"#)
    #expect((latest["answer"] as? String)?.hasPrefix("Two fixes") == true)
    #expect(!pane.commands.last!.hasSuffix("'1500000'"))
    let previous = try await read(pane, #"{"agent":"api","back":1}"#)
    #expect(previous["prompt"] as? String == "Fix the paste test with the clipboard stub")
    #expect(previous["answer"] as? String == "The paste test now uses the clipboard stub and passes.")
    #expect(previous["back"] as? Int == 1)
    #expect(pane.commands.last!.hasSuffix("'20000' '1500000'"))
    let tooFar = try await read(pane, #"{"agent":"api","back":9}"#)
    #expect((tooFar["error"] as? String)?.contains("4 turns") == true)
}

@MainActor
@Test func readAnswerListsRecentTurnsNewestFirstAndFindsTurnsByWords() async throws {
    let pane = TranscriptPane("claude-turns.jsonl")
    let listed = try await read(pane, #"{"agent":"api","which":"list","count":3}"#)
    let turns = try #require(listed["turns"] as? [[String: Any]])
    #expect(turns.map { $0["back"] as? Int } == [0, 1, 2])
    #expect(
        turns.map { $0["prompt"] as? String } == [
            "Summarize what changed today", "Fix the paste test with the clipboard stub",
            "Why does the reconnect test fail?",
        ])
    #expect(turns[1]["after_compaction"] as? Bool == true)
    #expect(listed["total"] as? Int == 4)

    let found = try await read(pane, #"{"agent":"api","query":"backoff timer"}"#)
    let matches = try #require(found["turns"] as? [[String: Any]])
    #expect(matches.map { $0["back"] as? Int } == [2])
    let none = try await read(pane, #"{"agent":"api","query":"kubernetes"}"#)
    #expect((none["error"] as? String)?.contains("kubernetes") == true)
}

@MainActor
@Test func longAnswersKeepTheirHeadAndTailAndSaySo() async throws {
    let long = String(repeating: "alpha ", count: 600) + "MIDDLE " + String(repeating: "omega ", count: 599) + "omega"
    let line =
        #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Explain everything"},"timestamp":"t"}"#
        + "\n"
        + #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":""#
        + long + #""}]},"timestamp":"t"}"#
    let clipped = AgentToolbox.clip(long, limit: 1000)
    #expect(clipped.truncated && clipped.text.count < 1100)
    #expect(clipped.text.hasPrefix("alpha") && clipped.text.hasSuffix("omega"))
    #expect(!clipped.text.contains("MIDDLE"))
    let turns = try #require(AgentTranscript.turns(kind: .claude, output: "@@psh-file:/x@@\n" + line))
    #expect(turns.first?.answer.last?.contains("MIDDLE") == true)
}
