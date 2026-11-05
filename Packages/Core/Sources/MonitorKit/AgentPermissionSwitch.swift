import Foundation
import TmuxKit

public enum AgentKind: String, Equatable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

public struct AgentProcess: Equatable, Sendable {
    public var pid: Int
    public var kind: AgentKind
    public var arguments: [String]
    public var cwd: String?
    public var sessionID: String?
    public var status: String?
    public var hasTranscript: Bool?

    public init(
        pid: Int, kind: AgentKind, arguments: [String], cwd: String? = nil, sessionID: String? = nil,
        status: String? = nil, hasTranscript: Bool? = nil
    ) {
        self.pid = pid
        self.kind = kind
        self.arguments = arguments
        self.cwd = cwd
        self.sessionID = sessionID
        self.status = status
        self.hasTranscript = hasTranscript
    }
}

public enum AgentPermissionSwitch {
    public enum Plan: Equatable, Sendable {
        case restartClaude(pid: Int, command: String)
        case codexFullAccess(pid: Int)

        public var pid: Int {
            switch self {
            case .restartClaude(let pid, _), .codexFullAccess(let pid): pid
            }
        }

        public var title: String {
            switch self {
            case .restartClaude: "Restart Claude without permission prompts?"
            case .codexFullAccess: "Give Codex Full Access?"
            }
        }

        public var message: String {
            switch self {
            case .restartClaude(_, let command) where !command.contains("--resume"):
                "This Claude session has no messages yet. Claude exits and starts again with:\n\n\(command)"
            case .restartClaude(_, let command):
                "Claude exits and resumes this conversation with:\n\n\(command)\n\nAn unsent prompt is discarded."
            case .codexFullAccess:
                "Codex switches this session to Full Access through /permissions: no approvals and no sandbox."
            }
        }
    }

    public enum Refusal: Error, Equatable, Sendable {
        case noAgent
        case busy(AgentKind)
        case noSessionID
        case canCycle
        case alreadyUnrestricted(AgentKind)

        public var message: String {
            switch self {
            case .noAgent:
                "No Claude or Codex session runs in this tab."
            case .busy(let kind):
                "\(kind.displayName) is working or waiting for an answer. Try again when it is idle."
            case .noSessionID:
                "PocketShell cannot find the session id of this Claude process, so it does not stop it."
            case .canCycle:
                "This Claude session already allows bypass mode. Press shift+tab (the mode key) until it shows bypass permissions on."
            case .alreadyUnrestricted(let kind):
                "\(kind.displayName) already runs without permission prompts."
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case restarted(command: String)
        case fullAccess
        case failed(String)
    }

    public struct IO {
        public var probe: @MainActor () async -> String?
        public var send: @MainActor (String) -> Void
        public var screen: @MainActor () -> String
        public var sleep: @MainActor (Duration) async -> Void

        public init(
            probe: @escaping @MainActor () async -> String?,
            send: @escaping @MainActor (String) -> Void,
            screen: @escaping @MainActor () -> String,
            sleep: @escaping @MainActor (Duration) async -> Void
        ) {
            self.probe = probe
            self.send = send
            self.screen = screen
            self.sleep = sleep
        }
    }

    /// Finds the shallowest Claude or Codex process below the pid printed by
    /// `rootCommand`; without one, below the sshd process serving this
    /// connection, which is also the parent of a plain shell tab.
    public static func probeCommand(rootCommand: String?) -> String {
        "sh -c \(shellQuote(probeScript)) sh \(shellQuote(rootCommand ?? ""))"
    }

    public static func hasRoot(_ output: String) -> Bool {
        output.hasPrefix("@@root:")
    }

    public static func parseProbe(_ output: String) -> AgentProcess? {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)[...]
        if lines.first?.hasPrefix("@@root:") == true { lines = lines.dropFirst() }
        guard let header = lines.popFirst(), header.hasPrefix("@@agent:"), header.hasSuffix("@@") else { return nil }
        let fields = header.dropFirst(8).dropLast(2).split(separator: ":")
        guard fields.count == 2, let pid = Int(fields[0]), let kind = AgentKind(rawValue: String(fields[1])) else {
            return nil
        }
        var sections: [String: [String]] = ["args": []]
        var current = "args"
        for line in lines {
            if line.hasPrefix("@@"), line.hasSuffix("@@"), line.count > 4 {
                current = String(line.dropFirst(2).dropLast(2))
                sections[current, default: []] = []
            } else {
                sections[current, default: []].append(line)
            }
        }
        let argv = (sections["args"] ?? []).filter { !$0.isEmpty }
        let start = argv.firstIndex { isExecutable($0, kind: kind) }.map { $0 + 1 } ?? min(1, argv.count)
        var process = AgentProcess(pid: pid, kind: kind, arguments: Array(argv[start...]))
        let session = (sections["session"] ?? []).joined(separator: "\n")
        if let data = session.data(using: .utf8), let file = try? JSONDecoder().decode(SessionFile.self, from: data),
            file.pid == nil || file.pid == pid
        {
            process.sessionID = file.sessionId
            process.cwd = file.cwd
            process.status = file.status
            process.hasTranscript = sections["transcript"] != nil
        }
        if process.sessionID == nil {
            process.sessionID = value(of: ["--resume", "-r", "--session-id"], in: process.arguments)
        }
        if process.cwd == nil {
            process.cwd = (sections["cwd"] ?? []).first { !$0.isEmpty }
        }
        return process
    }

    public static func plan(for process: AgentProcess?, status: AgentStatus?) -> Result<Plan, Refusal> {
        guard let process else { return .failure(.noAgent) }
        switch process.kind {
        case .claude:
            let args = process.arguments
            if args.contains("--dangerously-skip-permissions")
                || value(of: ["--permission-mode"], in: args) == "bypassPermissions"
            {
                return .failure(.alreadyUnrestricted(.claude))
            }
            if args.contains("--allow-dangerously-skip-permissions") { return .failure(.canCycle) }
            if status == .busy || status == .waiting { return .failure(.busy(.claude)) }
            if let state = process.status, state != "idle" { return .failure(.busy(.claude)) }
            guard let command = claudeResumeCommand(process) else { return .failure(.noSessionID) }
            return .success(.restartClaude(pid: process.pid, command: command))
        case .codex:
            let args = process.arguments
            if args.contains("--dangerously-bypass-approvals-and-sandbox") || args.contains("--yolo") {
                return .failure(.alreadyUnrestricted(.codex))
            }
            guard status == .idle else { return .failure(.busy(.codex)) }
            return .success(.codexFullAccess(pid: process.pid))
        }
    }

    public static func claudeResumeCommand(_ process: AgentProcess) -> String? {
        guard let id = process.sessionID, isSessionID(id) else { return nil }
        var command =
            process.hasTranscript == false
            ? "claude --dangerously-skip-permissions" : "claude --resume \(id) --dangerously-skip-permissions"
        for argument in keptClaudeArguments(process.arguments) {
            command += " " + (argument.allSatisfy(isPlainShellCharacter) ? argument : shellQuote(argument))
        }
        guard let cwd = process.cwd, !cwd.isEmpty else { return command }
        return "cd \(shellQuote(cwd)) && \(command)"
    }

    public static func keptClaudeArguments(_ arguments: [String]) -> [String] {
        var kept: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if keptClaudeSwitches.contains(argument) {
                kept.append(argument)
            } else if keptClaudeOptions.contains(name) {
                if argument.contains("=") {
                    kept.append(argument)
                } else if index + 1 < arguments.endIndex, !arguments[index + 1].hasPrefix("-") {
                    kept += [argument, arguments[index + 1]]
                    index += 1
                }
            }
            index += 1
        }
        return kept
    }

    public static func menuDigit(for option: String, in screen: String) -> String? {
        let pattern = "(\\d)\\.\\s+" + NSRegularExpression.escapedPattern(for: option)
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: screen, range: NSRange(screen.startIndex..., in: screen)),
            let range = Range(match.range(at: 1), in: screen)
        else { return nil }
        return String(screen[range])
    }

    @MainActor
    public static func run(_ plan: Plan, io: IO) async -> Outcome {
        switch plan {
        case .restartClaude(let pid, let command):
            io.send("\u{03}")
            await io.sleep(.milliseconds(250))
            io.send("\u{03}")
            var gone = 0
            for _ in 0..<20 where gone < 2 {
                await io.sleep(.milliseconds(400))
                let output = await io.probe()
                gone = output.map { hasRoot($0) && parseProbe($0)?.pid != pid } == true ? gone + 1 : 0
            }
            guard gone >= 2 else { return .failed("Claude did not exit, so PocketShell sent nothing else.") }
            await io.sleep(.milliseconds(300))
            io.send(command + "\r")
            return .restarted(command: command)
        case .codexFullAccess:
            io.send("\u{03}")
            await io.sleep(.milliseconds(300))
            io.send("/permissions")
            await io.sleep(.milliseconds(200))
            io.send("\r")
            guard let option = await waitForDigit("Full Access", io: io) else {
                io.send("\u{1b}")
                return .failed("Codex did not show its permissions menu.")
            }
            io.send(option)
            guard let confirm = await waitForDigit("Yes, continue anyway", io: io) else {
                return .failed("Codex did not ask to confirm Full Access. Check the session.")
            }
            io.send(confirm)
            return .fullAccess
        }
    }

    @MainActor
    private static func waitForDigit(_ option: String, io: IO) async -> String? {
        for _ in 0..<12 {
            await io.sleep(.milliseconds(250))
            if let digit = menuDigit(for: option, in: io.screen()) { return digit }
        }
        return nil
    }

    private static let keptClaudeOptions: Set<String> = [
        "--model", "--effort", "--agent", "--add-dir", "--settings", "--mcp-config", "--fallback-model",
        "--plugin-dir",
    ]
    private static let keptClaudeSwitches: Set<String> = [
        "--verbose", "--chrome", "--no-chrome", "--ide", "--strict-mcp-config",
    ]

    private static func value(of names: Set<String>, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard names.contains(parts[0]) else { continue }
            if parts.count == 2 { return parts[1] }
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") { return arguments[index + 1] }
        }
        return nil
    }

    private static func isExecutable(_ argument: String, kind: AgentKind) -> Bool {
        let name = argument.split(separator: "/").last.map(String.init) ?? argument
        return name == kind.rawValue || (kind == .claude && argument.contains("claude-code"))
    }

    private static func isSessionID(_ value: String) -> Bool {
        value.range(of: "^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$", options: .regularExpression) != nil
    }

    private static func isPlainShellCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "-_=./:@,+".contains(character))
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct SessionFile: Decodable {
        var pid: Int?
        var sessionId: String?
        var cwd: String?
        var status: String?
    }

    private static let probeScript = """
        root=
        if [ -n "$1" ]; then root=$(eval "$1" 2>/dev/null | head -n 1); else
        p=$$
        while [ "${p:-0}" -gt 1 ]; do
        case $(ps -o comm= -p "$p" 2>/dev/null) in *sshd*|*dropbear*) root=$p; break ;; esac
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        done
        fi
        case $root in ''|*[!0-9]*) exit 0 ;; esac
        echo "@@root:$root@@"
        set -- $(ps -A -o pid= -o ppid= -o args= | awk -v root="$root" '
        { parent[$1] = $2; name = $3; sub(/.*\\//, "", name); sub(/^-/, "", name)
        if (name == "node" || name == "bun" || name == "sh" || name == "bash") {
        name = $4; if (name ~ /claude-code/) name = "claude"; sub(/.*\\//, "", name) }
        if (name == "claude" || name == "codex") kind[$1] = name }
        END { best = ""; depth = 99
        for (pid in kind) { d = 0; q = pid
        while (q != "" && q != root && d < 64) { q = parent[q]; d++ }
        if (q == root && d < depth) { depth = d; best = pid } }
        if (best != "") print best, kind[best] }')
        [ -n "$1" ] || exit 0
        echo "@@agent:$1:$2@@"
        if [ -r "/proc/$1/cmdline" ]; then tr '\\0' '\\n' < "/proc/$1/cmdline"; echo
        else ps -o args= -p "$1" | tr ' ' '\\n'; fi
        f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$1.json"
        if [ "$2" = claude ] && [ -r "$f" ]; then echo "@@session@@"; cat "$f"; echo
        s=$(sed -n 's/.*"sessionId":"\\([^"]*\\)".*/\\1/p' "$f")
        for t in "${f%/sessions/*}"/projects/*/"$s".jsonl; do [ -n "$s" ] && [ -e "$t" ] && echo "@@transcript@@"; break; done
        else echo "@@cwd@@"
        readlink "/proc/$1/cwd" 2>/dev/null || lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'; fi
        exit 0
        """
}
