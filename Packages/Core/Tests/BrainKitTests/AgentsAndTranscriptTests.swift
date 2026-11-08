import Foundation
import MonitorKit
import Testing

@testable import BrainKit

@Test func parsesTmuxAndHerdrAgentsFromTheListOutput() throws {
    let agents = HostAgents.parse(
        try fixture("list-agents.txt"), current: CurrentTarget(tmuxSession: "work", windowIndex: 2, windowID: "@7"))
    #expect(agents.count == 3)
    let claude = try #require(agents.first { $0.kind == .claude })
    #expect(claude.location == .tmux(session: "work", windowIndex: 2, windowID: "@7", paneID: "%3"))
    #expect(claude.status == .busy)
    #expect(claude.cwd == "/home/dev/src/api")
    #expect(claude.pid == 4101)
    #expect(claude.spokenName == "Claude in api")
    #expect(claude.isCurrent)
    #expect(claude.preview.contains("Running the migration tests"))
    let codex = try #require(agents.first { $0.id == "tmux:%9" })
    #expect(codex.location == .tmux(session: "work", windowIndex: 4, windowID: "@11", paneID: "%9"))
    #expect(codex.name == "web|tools")
    #expect(codex.status == .idle)
    #expect(!codex.isCurrent)
    #expect(!codex.preview.contains("context left"))
    let reviewer = try #require(agents.first { $0.id == "herdr:default:w1:p3" })
    #expect(reviewer.kind == .codex)
    #expect(reviewer.status == .waiting)
    #expect(reviewer.name == "reviewer")
    #expect(reviewer.cwd == "/home/dev/src/infra")
    #expect(!reviewer.isCurrent)
}

@Test func focusedHerdrPaneIsCurrentInAHerdrTab() throws {
    let agents = HostAgents.parse(try fixture("list-agents.txt"), current: CurrentTarget(herdrSession: "default"))
    #expect(agents.filter(\.isCurrent).map(\.id) == ["herdr:default:w1:p3"])
}

@Test func resolverPrefersNamedThenCurrentAgents() throws {
    let agents = HostAgents.parse(
        try fixture("list-agents.txt"), current: CurrentTarget(tmuxSession: "work", windowIndex: 2))
    #expect(AgentResolver.resolve(nil, in: agents) == .found(agents.first { $0.kind == .claude }!))
    #expect(AgentResolver.resolve("claude", in: agents) == .found(agents.first { $0.kind == .claude }!))
    #expect(AgentResolver.resolve("the reviewer", in: agents) == .found(agents.first { $0.name == "reviewer" }!))
    #expect(AgentResolver.resolve("tab 4", in: agents) == .found(agents.first { $0.id == "tmux:%9" }!))
    #expect(AgentResolver.resolve("infra", in: agents) == .found(agents.first { $0.name == "reviewer" }!))
    if case .ambiguous(let options) = AgentResolver.resolve("codex", in: agents) {
        #expect(options.count == 2)
    } else {
        Issue.record("two Codex agents must be ambiguous")
    }
    #expect(AgentResolver.resolve("gemini", in: agents) == .none)
}

@Test func extractsClaudeLastAnswerAndFullTurnFromTheTranscript() throws {
    let output =
        "@@psh-file:/home/dev/.claude/projects/-home-dev-src-api/5b3c.jsonl@@\n"
        + (try fixture("claude-transcript.jsonl"))
    let answer = try #require(AgentTranscript.parse(kind: .claude, output: output))
    #expect(answer.prompt == "Now add a migration and run the tests")
    #expect(answer.last == "The migration is in place and all 42 tests pass.")
    #expect(answer.full == "I'll write the migration first.\n\nThe migration is in place and all 42 tests pass.")
    #expect(answer.full?.contains("Subagent") == false)
}

@Test func extractsCodexLastAnswerAndFullTurnFromTheRollout() throws {
    let output =
        "@@psh-file:/home/dev/.codex/sessions/2026/11/08/rollout-x.jsonl@@\n" + (try fixture("codex-rollout.jsonl"))
    let answer = try #require(AgentTranscript.parse(kind: .codex, output: output))
    #expect(answer.prompt == "Fix the flaky login test")
    #expect(answer.last == "The login test waited on a fixed sleep. It now waits for the session cookie.")
    #expect(
        answer.full
            == "I will look at the login test first.\n\nThe login test waited on a fixed sleep. It now waits for the session cookie."
    )
}

@Test func missingTranscriptParsesToNil() {
    #expect(AgentTranscript.parse(kind: .claude, output: "@@psh-none@@\n") == nil)
}

@Test func controlCommandsTargetTheRightPaneOrHerdrAgent() {
    let tmux = BrainAgent(
        kind: .claude, name: "api", location: .tmux(session: "work", windowIndex: 2, windowID: "@7", paneID: "%3"),
        status: .idle)
    let herdr = BrainAgent(
        kind: .codex, name: "reviewer",
        location: .herdr(session: "lab", paneID: "w1:p3", tabID: "w1:t1", workspaceID: "w1"),
        status: .waiting)
    #expect(
        AgentControl.promptCommand(tmux, text: "it's done?\nship it").hasSuffix(
            "send-keys -t '%3' -l -- 'it'\\''s done? ship it' && sleep 0.3 && PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux send-keys -t '%3' Enter"
        ))
    #expect(AgentControl.promptCommand(herdr, text: "go").contains("--session 'lab' agent prompt 'w1:p3' 'go' 2>&1"))
    #expect(AgentControl.keyCommand(tmux, key: .ctrlC).hasSuffix("send-keys -t '%3' C-c"))
    #expect(AgentControl.keyCommand(herdr, key: .esc).contains("agent send-keys 'w1:p3' esc"))
    #expect(AgentControl.textCommand(herdr, text: "2").contains("pane send-text 'w1:p3' '2'"))
    #expect(AgentControl.screenCommand(herdr).contains("pane read 'w1:p3' --source visible"))
    #expect(AgentControl.transcriptCommand(herdr).contains("pane process-info --pane"))
    #expect(
        AgentControl.herdrFailure(#"{"error":{"code":"agent_blocked","message":"agent is blocked"}}"#)
            == "agent is blocked")
    #expect(AgentControl.herdrFailure(#"{"result":{"ok":true}}"#) == nil)
}

@Test func checkedCommandsReportTheirExitStatus() async throws {
    let wrapped = AgentControl.checked("echo out; exit 3")
    #expect(wrapped.hasPrefix("( echo out; exit 3 ) 2>&1;"))
    #expect(AgentControl.splitExit("out\n@@psh-exit:3@@") == ("out", 3))
    #expect(AgentControl.splitExit("fine") == ("fine", 0))
    #if os(macOS)
        let output = try await run(AgentControl.checked("echo out; exit 4"), environment: [:])
        #expect(AgentControl.splitExit(output) == ("out", 4))
    #endif
}

@Test func optionDigitsComeFromNumbersWordsOrLabels() {
    let screen = "Which database?\n❯ 1. Postgres\n  2. SQLite\nEnter to select"
    #expect(AgentControl.optionDigit("2", screen: nil) == "2")
    #expect(AgentControl.optionDigit("two", screen: nil) == "2")
    #expect(AgentControl.optionDigit("option 1", screen: nil) == "1")
    #expect(AgentControl.optionDigit("sqlite", screen: screen) == "2")
    #expect(AgentControl.optionDigit("mysql", screen: screen) == nil)
    #expect(AgentControl.optionLabel("1", screen: screen) == "Postgres")
}

#if os(macOS)
    private func run(_ command: String, environment: [String: String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        return String(decoding: data, as: UTF8.self)
    }

    private func hasTmux() -> Bool {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    @Test(.enabled(if: hasTmux()))
    func listScriptFindsAgentsInPrivateTmuxPanesAndReadsTheirTranscript() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "psh-brain-\(UUID().uuidString.prefix(8))")
        let environment = [
            "HOME": home.path, "TMUX_TMPDIR": home.appendingPathComponent("tmux").path, "TMPDIR": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        ]
        do {
            try await listAndReadAgents(home: home, environment: environment)
        } catch {
            await tearDown(home: home, environment: environment)
            throw error
        }
        await tearDown(home: home, environment: environment)
    }

    private func tearDown(home: URL, environment: [String: String]) async {
        _ = try? await run("tmux kill-server; pkill -f '\(home.path)/bin/'; true", environment: environment)
        try? FileManager.default.removeItem(at: home)
    }

    private func listAndReadAgents(home: URL, environment: [String: String]) async throws {
        let fake = home.appendingPathComponent("bin")
        let project = home.appendingPathComponent("src/api")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("tmux"), withIntermediateDirectories: true)
        let agentScript =
            "#!/bin/sh\nprintf 'Hello from the agent\\n\\n? for shortcuts\\n'\nwhile :; do sleep 1; done\n"
        for name in ["claude", "codex"] {
            let url = fake.appendingPathComponent(name)
            try agentScript.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        _ = try await run(
            "tmux new-session -d -s brainwork -n api -c '\(project.path)' '\(fake.path)/claude --resume x'"
                + " && tmux set-option -t brainwork automatic-rename off"
                + " && tmux new-window -t brainwork -n shell"
                + " && tmux new-session -d -t brainwork -s brainwork-psh-0a1b2c3d",
            environment: environment)
        try await Task.sleep(for: .milliseconds(600))
        let output = try await run(HostAgents.listCommand(), environment: environment)
        let agents = HostAgents.parse(output, current: CurrentTarget(tmuxSession: "brainwork", windowIndex: 0))
        #expect(agents.count == 1)
        let agent = try #require(agents.first)
        let pid = try #require(agent.pid)
        #expect(agent.kind == .claude)
        #expect(agent.name == "api")
        #expect(agent.isCurrent)
        #expect(agent.status == .idle)
        #expect(agent.cwd?.hasSuffix("/src/api") == true)
        #expect(agent.preview.contains("Hello from the agent"))
        if case .tmux(let session, let index, _, _) = agent.location {
            #expect(session == "brainwork")
            #expect(index == 0)
        }

        let sessions = home.appendingPathComponent(".claude/sessions")
        let transcripts = home.appendingPathComponent(".claude/projects/x")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let id = "5b3c0a52-7d1e-4c8e-9f20-1a2b3c4d5e6f"
        try #"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"\#(project.path)","status":"busy"}"#.write(
            to: sessions.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        try fixture("claude-transcript.jsonl").write(
            to: transcripts.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        let relisted = HostAgents.parse(try await run(HostAgents.listCommand(), environment: environment))
        #expect(relisted.first?.status == .busy)
        #expect(relisted.first?.cwd == project.path)

        let transcript = try await run(AgentControl.transcriptCommand(agent), environment: environment)
        let answer = try #require(AgentTranscript.parse(kind: .claude, output: transcript))
        #expect(answer.last == "The migration is in place and all 42 tests pass.")
    }
#endif
