import Foundation
import HerdrKit
import MonitorKit
import TmuxKit

public struct BrainAgent: Equatable, Sendable, Identifiable {
    public enum Location: Equatable, Sendable {
        case tmux(session: String, windowIndex: Int, windowID: String, paneID: String)
        case herdr(session: String, paneID: String, tabID: String, workspaceID: String)
    }

    public enum Status: String, Equatable, Sendable {
        case busy, waiting, idle, done, unknown
    }

    public var kind: AgentKind
    public var name: String
    public var location: Location
    public var status: Status
    public var cwd: String?
    public var pid: Int?
    public var preview: String
    public var isCurrent = false
    public var prompt: InteractivePrompt?

    public init(
        kind: AgentKind, name: String, location: Location, status: Status, cwd: String? = nil, pid: Int? = nil,
        preview: String = "", isCurrent: Bool = false, prompt: InteractivePrompt? = nil
    ) {
        self.kind = kind
        self.name = name
        self.location = location
        self.status = status
        self.cwd = cwd
        self.pid = pid
        self.preview = preview
        self.isCurrent = isCurrent
        self.prompt = prompt
    }

    public var id: String {
        switch location {
        case .tmux(_, _, _, let paneID): "tmux:\(paneID)"
        case .herdr(let session, let paneID, _, _): "herdr:\(session):\(paneID)"
        }
    }

    public var spokenName: String {
        let place = name.isEmpty ? (cwd.map { ($0 as NSString).lastPathComponent } ?? "") : name
        return place.isEmpty || place.lowercased() == kind.rawValue
            ? kind.displayName : "\(kind.displayName) in \(place)"
    }

    public var activityStatus: AgentStatus {
        switch status {
        case .busy: .busy
        case .waiting: .waiting
        case .idle, .done, .unknown: .idle
        }
    }

    public var where_: String {
        switch location {
        case .tmux(let session, let windowIndex, _, _): "tmux \(session):\(windowIndex)"
        case .herdr(let session, _, _, _): "herdr \(session)"
        }
    }
}

public struct CurrentTarget: Equatable, Sendable {
    public var tmuxSession: String?
    public var windowIndex: Int?
    public var windowID: String?
    public var herdrSession: String?

    public init(
        tmuxSession: String? = nil, windowIndex: Int? = nil, windowID: String? = nil, herdrSession: String? = nil
    ) {
        self.tmuxSession = tmuxSession
        self.windowIndex = windowIndex
        self.windowID = windowID
        self.herdrSession = herdrSession
    }
}

public enum HostAgents {
    static let path = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin\"; export PATH"

    public static func listCommand() -> String {
        "sh -c \(shellQuote(listScript))"
    }

    public static func parse(_ output: String, current: CurrentTarget? = nil) -> [BrainAgent] {
        var agents: [BrainAgent] = []
        var focusedHerdrPanes: [String: String] = [:]
        for block in blocks(output) {
            if block.header.hasPrefix("tmux:") {
                if let agent = tmuxAgent(block) { agents.append(agent) }
            } else if block.header.hasPrefix("herdr:") {
                let session = String(block.header.dropFirst(6))
                guard let snapshot = Herdr.parseSnapshot(block.sections["", default: ""]) else { continue }
                focusedHerdrPanes[session] = snapshot.focusedPaneID
                agents += herdrAgents(snapshot, session: session)
            }
        }
        guard let current else { return agents }
        return agents.map { agent in
            var agent = agent
            switch agent.location {
            case .tmux(let session, let windowIndex, let windowID, _):
                agent.isCurrent =
                    current.herdrSession == nil && Tmux.baseSessionName(current.tmuxSession ?? "") == session
                    && (current.windowID.map { $0 == windowID } ?? (current.windowIndex == windowIndex))
            case .herdr(let session, let paneID, _, _):
                agent.isCurrent = current.herdrSession == session && focusedHerdrPanes[session] == paneID
            }
            return agent
        }
    }

    static func status(screen: String, sessionStatus: String?) -> BrainAgent.Status {
        if let detected = AgentStatus.detectAgent(screen) {
            switch detected {
            case .busy: return .busy
            case .waiting: return .waiting
            case .idle: break
            }
        }
        switch sessionStatus?.lowercased() {
        case "busy", "working", "running", "thinking": return .busy
        case "waiting", "blocked", "needs_input", "permission": return .waiting
        default: return .idle
        }
    }

    static func preview(_ screen: String) -> String {
        let chrome = [
            "? for shortcuts", "shift+tab", "esc to interrupt", "context left", "% used", "bypass permissions",
            "accept edits", "auto mode", "plan mode",
        ]
        let lines = screen.split(separator: "\n").map { line in
            String(line.filter { !"─━═│┃╭╮╰╯┌┐└┘├┤".contains($0) }).trimmingCharacters(in: .whitespaces)
        }
        let meaningful = lines.filter { line in
            let lowered = line.lowercased()
            return line.count > 2 && line.contains(where: \.isLetter) && !chrome.contains(where: lowered.contains)
        }
        return String(meaningful.suffix(3).joined(separator: " / ").prefix(240))
    }

    private struct Block {
        var header: String
        var sections: [String: String]
    }

    private static func blocks(_ output: String) -> [Block] {
        var result: [Block] = []
        var section = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@psh-"), line.hasSuffix("@@") {
                let marker = String(line.dropFirst(6).dropLast(2))
                if marker.hasPrefix("tmux:") || marker.hasPrefix("herdr:") {
                    result.append(Block(header: marker, sections: [:]))
                    section = ""
                } else {
                    section = marker
                }
                continue
            }
            guard !result.isEmpty else { continue }
            let existing = result[result.count - 1].sections[section]
            result[result.count - 1].sections[section] = existing.map { $0 + "\n" + line } ?? String(line)
        }
        return result
    }

    private static func tmuxAgent(_ block: Block) -> BrainAgent? {
        let fields = block.header.dropFirst(5).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 7, let pid = Int(fields[1]), let kind = AgentKind(rawValue: fields[2]),
            let windowIndex = Int(fields[4])
        else { return nil }
        let screen = block.sections["screen"] ?? ""
        var sessionStatus: String?
        var cwd = block.sections["cwd"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = block.sections["session"]?.data(using: .utf8),
            let file = try? JSONDecoder().decode(SessionFile.self, from: json)
        {
            sessionStatus = file.status
            if let fileCwd = file.cwd, !fileCwd.isEmpty { cwd = fileCwd }
        }
        let windowName = fields[6...].joined(separator: "|")
        let status = status(screen: screen, sessionStatus: sessionStatus)
        return BrainAgent(
            kind: kind, name: Tmux.isPlaceholderWindowName(windowName) ? "" : windowName,
            location: .tmux(
                session: Tmux.baseSessionName(fields[3]), windowIndex: windowIndex, windowID: fields[5],
                paneID: fields[0]),
            status: status, cwd: cwd?.isEmpty == false ? cwd : nil, pid: pid, preview: preview(screen),
            prompt: status == .waiting ? InteractivePrompt.read(screen) : nil)
    }

    private static func herdrAgents(_ snapshot: HerdrSnapshot, session: String) -> [BrainAgent] {
        let panes = Dictionary((snapshot.panes ?? []).map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        let tabs = Dictionary((snapshot.tabs ?? []).map { ($0.tabID, $0) }, uniquingKeysWith: { first, _ in first })
        return snapshot.agents.compactMap { agent in
            guard let kind = (agent.agent ?? agent.displayAgent).flatMap({ AgentKind(rawValue: $0.lowercased()) })
            else { return nil }
            let status: BrainAgent.Status =
                switch agent.status {
                case .working: .busy
                case .blocked: .waiting
                case .done: .done
                case .idle: .idle
                case .unknown: .unknown
                }
            let pane = panes[agent.paneID]
            let label = [agent.name, tabs[agent.tabID]?.label].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            return BrainAgent(
                kind: kind, name: label,
                location: .herdr(
                    session: session, paneID: agent.paneID, tabID: agent.tabID, workspaceID: agent.workspaceID),
                status: status, cwd: pane?.foregroundCwd ?? pane?.cwd, preview: agent.title ?? "")
        }
    }

    private struct SessionFile: Decodable {
        var cwd: String?
        var status: String?
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let agentAwk = """
        { parent[$1] = $2; name = $3; sub(/.*\\//, "", name); sub(/^-/, "", name)
        if (name == "herdr") herdr[$1] = 1
        if (name == "node" || name == "bun" || name == "sh" || name == "bash") {
        name = $4; if (name ~ /claude-code/) name = "claude"; sub(/.*\\//, "", name) }
        if ((name == "claude" || name == "codex") && $4 != "app-server") kind[$1] = name }
        """

    static let listScript = """
        \(path)
        \(HostLayout.windowsScript)
        ps -A -o pid= -o ppid= -o args= > "${TMPDIR:-/tmp}/psh-brain-ps.$$" 2>/dev/null
        tmux list-panes -a -F '#{pane_id}|#{pane_pid}|#{session_name}|#{window_index}|#{window_id}|#{window_name}' 2>/dev/null |
        awk -F'|' '{ clone = ($3 ~ /-psh-[0-9a-f]+$/) ? 1 : 0
        if (!($1 in seen) || (seenclone[$1] && !clone)) { seen[$1] = $0; seenclone[$1] = clone } }
        END { for (p in seen) print seen[p] }' > "${TMPDIR:-/tmp}/psh-brain-panes.$$"
        awk -v panes="${TMPDIR:-/tmp}/psh-brain-panes.$$" '
        \(agentAwk)
        END { while ((getline line < panes) > 0) { split(line, f, "|"); root[f[2]] = line }
        for (pid in kind) { d = 0; q = pid; bad = 0
        while (q != "" && !(q in root) && d < 64) { q = parent[q]; d++; if (q in herdr) bad = 1 }
        if (q in root && !bad && (!(q in depth) || d < depth[q])) { depth[q] = d; best[q] = pid } }
        for (q in best) { split(root[q], f, "|"); rest = root[q]; sub(/^[^|]*\\|[^|]*\\|/, "", rest)
        print f[1] "|" best[q] "|" kind[best[q]] "|" rest } }' "${TMPDIR:-/tmp}/psh-brain-ps.$$" |
        while IFS='|' read -r pane pid kind rest; do
        echo "@@psh-tmux:$pane|$pid|$kind|$rest@@"
        f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$pid.json"
        if [ "$kind" = claude ] && [ -r "$f" ]; then echo "@@psh-session@@"; head -c 4000 "$f"; echo; fi
        echo "@@psh-cwd@@"
        readlink "/proc/$pid/cwd" 2>/dev/null || lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
        echo "@@psh-screen@@"
        tmux capture-pane -p -t "$pane" 2>/dev/null | tail -n 40
        done
        rm -f "${TMPDIR:-/tmp}/psh-brain-ps.$$" "${TMPDIR:-/tmp}/psh-brain-panes.$$"
        if command -v herdr >/dev/null 2>&1; then
        for s in $(herdr session list --json 2>/dev/null | tr '{' '\\n' | grep '"running":true' | sed -n 's/.*"name":"\\([^"]*\\)".*/\\1/p'); do
        case "$s" in "${PSH_HERDR_ONLY:-}"*) ;; *) continue ;; esac
        echo "@@psh-herdr:$s@@"
        if [ "$s" = default ]; then herdr api snapshot 2>/dev/null; else herdr --session "$s" api snapshot 2>/dev/null; fi
        echo
        done
        fi
        exit 0
        """
}
