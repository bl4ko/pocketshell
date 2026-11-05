import Foundation
import MonitorKit
import Testing
import TmuxKit

private let sessionID = "1020da0a-c3c5-432b-8125-d3d7353dd617"

private func claudeProbe(args: String, status: String = "idle", transcript: Bool = true) -> String {
    """
    @@root:19065@@
    @@agent:21569:claude@@
    \(args.split(separator: " ").joined(separator: "\n"))
    @@session@@
    {"pid":21569,"sessionId":"\(sessionID)","cwd":"/private/tmp/my project","status":"\(status)","kind":"interactive"}

    \(transcript ? "@@transcript@@\n" : "")
    """
}

@Test func parsesClaudeProbeFromTheSessionFile() throws {
    let process = try #require(
        AgentPermissionSwitch.parseProbe(claudeProbe(args: "claude --resume 81bd321d-b732-417f-ad40-fd4503e562eb")))
    #expect(process.pid == 21569)
    #expect(process.kind == .claude)
    #expect(process.arguments == ["--resume", "81bd321d-b732-417f-ad40-fd4503e562eb"])
    #expect(process.sessionID == sessionID)
    #expect(process.cwd == "/private/tmp/my project")
    #expect(process.status == "idle")
    #expect(process.hasTranscript == true)
}

@Test func fallsBackToArgumentsWithoutASessionFile() throws {
    let output = """
        @@root:42@@
        @@agent:42418:claude@@
        /tmp/fake/claude
        --session-id
        11111111-2222-3333-4444-555555555555
        @@cwd@@
        /private/tmp/psh

        """
    let process = try #require(AgentPermissionSwitch.parseProbe(output))
    #expect(process.sessionID == "11111111-2222-3333-4444-555555555555")
    #expect(process.cwd == "/private/tmp/psh")
    #expect(process.status == nil)
}

@Test func skipsInterpreterArgumentsOfNodeInstalls() throws {
    let output = """
        @@agent:7:claude@@
        node
        /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js
        --model
        opus

        """
    let process = try #require(AgentPermissionSwitch.parseProbe(output))
    #expect(process.arguments == ["--model", "opus"])
}

@Test func probeWithoutAnAgentParsesToNil() {
    #expect(AgentPermissionSwitch.parseProbe("@@root:19065@@\n") == nil)
    #expect(AgentPermissionSwitch.hasRoot("@@root:19065@@\n"))
    #expect(!AgentPermissionSwitch.hasRoot(""))
    #expect(AgentPermissionSwitch.parseProbe("@@agent:x:claude@@\n") == nil)
    #expect(AgentPermissionSwitch.parseProbe("@@agent:5:vim@@\n") == nil)
}

@Test func ignoresASessionFileOfAnotherProcess() throws {
    let output = """
        @@agent:5:claude@@
        claude
        @@session@@
        {"pid":6,"sessionId":"\(sessionID)","cwd":"/x","status":"idle"}

        """
    let process = try #require(AgentPermissionSwitch.parseProbe(output))
    #expect(process.sessionID == nil)
}

@Test func resumesTheCurrentSessionInItsDirectoryWithKeptFlags() throws {
    let process = try #require(
        AgentPermissionSwitch.parseProbe(
            claudeProbe(
                args:
                    "claude --model opus --resume 81bd321d-b732-417f-ad40-fd4503e562eb --permission-mode auto --effort=high fix-the-bug --verbose"
            )))
    #expect(
        AgentPermissionSwitch.claudeResumeCommand(process)
            == "cd '/private/tmp/my project' && claude --resume \(sessionID) --dangerously-skip-permissions --model opus --effort=high --verbose"
    )
}

@Test func startsAFreshSessionWhenTheOldOneHasNoMessages() throws {
    let process = try #require(
        AgentPermissionSwitch.parseProbe(claudeProbe(args: "claude --model opus", transcript: false)))
    #expect(process.hasTranscript == false)
    let command = "cd '/private/tmp/my project' && claude --dangerously-skip-permissions --model opus"
    #expect(AgentPermissionSwitch.claudeResumeCommand(process) == command)
    let plan = AgentPermissionSwitch.Plan.restartClaude(pid: 21569, command: command)
    #expect(AgentPermissionSwitch.plan(for: process, status: .idle) == .success(plan))
    #expect(plan.message.hasPrefix("This Claude session has no messages yet."))
}

@Test func quotesKeptValuesThatNeedIt() {
    #expect(
        AgentPermissionSwitch.keptClaudeArguments(["--add-dir", "/a b", "--model", "claude's", "-p", "hi"])
            == ["--add-dir", "/a b", "--model", "claude's"])
    let process = AgentProcess(pid: 1, kind: .claude, arguments: ["--add-dir", "/a b"], sessionID: sessionID)
    #expect(
        AgentPermissionSwitch.claudeResumeCommand(process)
            == "claude --resume \(sessionID) --dangerously-skip-permissions --add-dir '/a b'")
}

@Test func refusesASessionIDThatIsNotAUUID() {
    let process = AgentProcess(pid: 1, kind: .claude, arguments: [], sessionID: "x; rm -rf ~")
    #expect(AgentPermissionSwitch.claudeResumeCommand(process) == nil)
    #expect(AgentPermissionSwitch.plan(for: process, status: .idle) == .failure(.noSessionID))
}

@Test func plansAClaudeRestartOnlyWhenIdle() throws {
    let process = try #require(AgentPermissionSwitch.parseProbe(claudeProbe(args: "claude")))
    let command = "cd '/private/tmp/my project' && claude --resume \(sessionID) --dangerously-skip-permissions"
    #expect(
        AgentPermissionSwitch.plan(for: process, status: .idle)
            == .success(.restartClaude(pid: 21569, command: command)))
    #expect(
        AgentPermissionSwitch.plan(for: process, status: nil) == .success(.restartClaude(pid: 21569, command: command)))
    #expect(AgentPermissionSwitch.plan(for: process, status: .busy) == .failure(.busy(.claude)))
    #expect(AgentPermissionSwitch.plan(for: process, status: .waiting) == .failure(.busy(.claude)))
    let working = try #require(AgentPermissionSwitch.parseProbe(claudeProbe(args: "claude", status: "busy")))
    #expect(AgentPermissionSwitch.plan(for: working, status: .idle) == .failure(.busy(.claude)))
    #expect(AgentPermissionSwitch.plan(for: nil, status: .idle) == .failure(.noAgent))
}

@Test func doesNotRestartAClaudeThatCanAlreadyBypass() throws {
    let skipping = try #require(
        AgentPermissionSwitch.parseProbe(claudeProbe(args: "claude --dangerously-skip-permissions")))
    #expect(AgentPermissionSwitch.plan(for: skipping, status: .idle) == .failure(.alreadyUnrestricted(.claude)))
    let bypassMode = try #require(
        AgentPermissionSwitch.parseProbe(claudeProbe(args: "claude --permission-mode bypassPermissions")))
    #expect(AgentPermissionSwitch.plan(for: bypassMode, status: .idle) == .failure(.alreadyUnrestricted(.claude)))
    let cycling = try #require(
        AgentPermissionSwitch.parseProbe(claudeProbe(args: "claude --allow-dangerously-skip-permissions")))
    #expect(AgentPermissionSwitch.plan(for: cycling, status: .idle) == .failure(.canCycle))
}

@Test func plansCodexFullAccessOnlyWhenIdle() {
    let codex = AgentProcess(pid: 9, kind: .codex, arguments: [])
    #expect(AgentPermissionSwitch.plan(for: codex, status: .idle) == .success(.codexFullAccess(pid: 9)))
    #expect(AgentPermissionSwitch.plan(for: codex, status: nil) == .failure(.busy(.codex)))
    #expect(AgentPermissionSwitch.plan(for: codex, status: .busy) == .failure(.busy(.codex)))
    let yolo = AgentProcess(pid: 9, kind: .codex, arguments: ["resume", "--yolo"])
    #expect(AgentPermissionSwitch.plan(for: yolo, status: .idle) == .failure(.alreadyUnrestricted(.codex)))
}

@Test func findsNumberedMenuOptions() {
    let menu = """
          Update Model Permissions
        › 1. Ask for approval  Read and edit workspace files
          2. Approve for me    Only ask for actions detected as potentially unsafe
          3. Full Access       Use with caution
          4. Read Only         Read workspace files
        """
    #expect(AgentPermissionSwitch.menuDigit(for: "Full Access", in: menu) == "3")
    #expect(AgentPermissionSwitch.menuDigit(for: "Yes, continue anyway", in: menu) == nil)
    #expect(
        AgentPermissionSwitch.menuDigit(for: "Yes, continue anyway", in: "› 1. Yes, continue anyway  Apply") == "1")
}

@MainActor
private final class FakeTerminal {
    var sent: [String] = []
    var probes: [String?]
    var screens: [String]

    init(probes: [String?] = [], screens: [String] = []) {
        self.probes = probes
        self.screens = screens
    }

    var io: AgentPermissionSwitch.IO {
        AgentPermissionSwitch.IO(
            probe: { self.probes.isEmpty ? "@@root:1@@\n" : self.probes.removeFirst() },
            send: { self.sent.append($0) },
            screen: { self.screens.count > 1 ? self.screens.removeFirst() : self.screens.first ?? "" },
            sleep: { _ in }
        )
    }
}

@MainActor
@Test func restartsClaudeOnlyAfterItsProcessIsGone() async {
    let running = claudeProbe(args: "claude")
    let terminal = FakeTerminal(probes: [running, nil, "@@root:19065@@\n", "", "@@root:19065@@\n", "@@root:19065@@\n"])
    let outcome = await AgentPermissionSwitch.run(
        .restartClaude(pid: 21569, command: "claude --resume x"), io: terminal.io)
    #expect(outcome == .restarted(command: "claude --resume x"))
    #expect(terminal.sent == ["\u{03}", "\u{03}", "claude --resume x\r"])
    #expect(terminal.probes.isEmpty)
}

@MainActor
@Test func sendsNothingWhenClaudeDoesNotExit() async {
    let running = claudeProbe(args: "claude")
    let terminal = FakeTerminal(probes: Array(repeating: running, count: 20))
    let outcome = await AgentPermissionSwitch.run(
        .restartClaude(pid: 21569, command: "claude --resume x"), io: terminal.io)
    #expect(outcome == .failed("Claude did not exit, so PocketShell sent nothing else."))
    #expect(terminal.sent == ["\u{03}", "\u{03}"])
}

@MainActor
@Test func switchesCodexThroughItsPermissionsMenu() async {
    let terminal = FakeTerminal(screens: [
        "› /permissions",
        "  2. Approve for me\n  3. Full Access   Use with caution",
        "  2. Approve for me\n  3. Full Access   Use with caution",
        "› 1. Yes, continue anyway  Apply full access\n  2. Cancel",
    ])
    let outcome = await AgentPermissionSwitch.run(.codexFullAccess(pid: 9), io: terminal.io)
    #expect(outcome == .fullAccess)
    #expect(terminal.sent == ["\u{03}", "/permissions", "\r", "3", "1"])
}

@MainActor
@Test func backsOutWhenCodexShowsNoMenu() async {
    let terminal = FakeTerminal(screens: ["› Ask Codex to do anything"])
    let outcome = await AgentPermissionSwitch.run(.codexFullAccess(pid: 9), io: terminal.io)
    #expect(outcome == .failed("Codex did not show its permissions menu."))
    #expect(terminal.sent == ["\u{03}", "/permissions", "\r", "\u{1b}"])
}

#if os(macOS)
    @Test func probeScriptFindsTheShallowestAgentBelowTheRoot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("psh-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = directory.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(atPath: fake.path, withDestinationPath: "/bin/sleep")
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "\(fake.path) 30 & wait"]
        parent.currentDirectoryURL = directory
        try parent.run()
        defer { parent.terminate() }
        var output = ""
        for _ in 0..<50 where AgentPermissionSwitch.parseProbe(output) == nil {
            try await Task.sleep(for: .milliseconds(100))
            output = try runShell(AgentPermissionSwitch.probeCommand(rootCommand: "echo \(parent.processIdentifier)"))
        }
        #expect(AgentPermissionSwitch.hasRoot(output))
        let process = try #require(AgentPermissionSwitch.parseProbe(output))
        #expect(process.kind == .claude)
        #expect(process.arguments == ["30"])
        #expect(process.cwd?.hasSuffix(directory.lastPathComponent) == true)
        defer { kill(pid_t(process.pid), SIGTERM) }

        let config = directory.appendingPathComponent("config")
        let transcript = config.appendingPathComponent("projects/-tmp-x/\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: config.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try Data(#"{"pid":\#(process.pid),"sessionId":"\#(sessionID)","cwd":"/tmp/x","status":"idle"}"#.utf8)
            .write(to: config.appendingPathComponent("sessions/\(process.pid).json"))
        try Data().write(to: transcript)
        let probe = AgentPermissionSwitch.probeCommand(rootCommand: "echo \(parent.processIdentifier)")
        let resumable = try #require(
            AgentPermissionSwitch.parseProbe(try runShell("CLAUDE_CONFIG_DIR='\(config.path)' \(probe)")))
        #expect(resumable.sessionID == sessionID)
        #expect(resumable.cwd == "/tmp/x")
        #expect(resumable.hasTranscript == true)
        try FileManager.default.removeItem(at: transcript)
        let empty = try #require(
            AgentPermissionSwitch.parseProbe(try runShell("CLAUDE_CONFIG_DIR='\(config.path)' \(probe)")))
        #expect(empty.sessionID == sessionID)
        #expect(empty.hasTranscript == false)

        let elsewhere = try runShell(AgentPermissionSwitch.probeCommand(rootCommand: "echo 999999"))
        #expect(AgentPermissionSwitch.hasRoot(elsewhere))
        #expect(AgentPermissionSwitch.parseProbe(elsewhere) == nil)
        #expect(try runShell(AgentPermissionSwitch.probeCommand(rootCommand: "false")) == "")
    }

    private func runShell(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning { usleep(10_000) }
        return String(decoding: data, as: UTF8.self)
    }
#endif
