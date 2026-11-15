import Foundation
import MonitorKit

public struct AgentAnswer: Equatable, Sendable {
    public var prompt: String?
    public var blocks: [String]
    public var final: String?

    public init(prompt: String?, blocks: [String], final: String? = nil) {
        self.prompt = prompt
        self.blocks = blocks
        self.final = final
    }

    public var last: String? { final ?? blocks.last }
    public var full: String? { blocks.isEmpty ? final : blocks.joined(separator: "\n\n") }
}

public struct AgentTurn: Equatable, Sendable {
    public var prompt: String?
    public var blocks: [String]
    public var final: String?
    public var time: String?
    public var afterCompaction: Bool

    public init(
        prompt: String? = nil, blocks: [String] = [], final: String? = nil, time: String? = nil,
        afterCompaction: Bool = false
    ) {
        self.prompt = prompt
        self.blocks = blocks
        self.final = final
        self.time = time
        self.afterCompaction = afterCompaction
    }

    public var answer: AgentAnswer { AgentAnswer(prompt: prompt, blocks: blocks, final: final) }
}

public enum AgentTranscript {
    public static let narrowWindow = (lines: 1500, bytes: 600_000)
    public static let wideWindow = (lines: 20000, bytes: 1_500_000)

    public static func command(kind: AgentKind, pid: Int?, rootCommand: String?, cwd: String?, wide: Bool = false)
        -> String
    {
        let window = wide ? wideWindow : narrowWindow
        let arguments = [
            kind.rawValue, pid.map(String.init) ?? "", rootCommand ?? "", cwd ?? "", String(window.lines),
            String(window.bytes),
        ]
        return "sh -c \(HostAgents.shellQuote(script)) sh "
            + arguments.map(HostAgents.shellQuote).joined(separator: " ")
    }

    public static func transcriptPath(_ output: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix("@@psh-file:") && $0.hasSuffix("@@") }.map {
            String($0.dropFirst(11).dropLast(2))
        }
    }

    public static func parse(kind: AgentKind, output: String) -> AgentAnswer? {
        turns(kind: kind, output: output).map { $0.last?.answer ?? AgentAnswer(prompt: nil, blocks: []) }
    }

    public static func turns(kind: AgentKind, output: String) -> [AgentTurn]? {
        guard transcriptPath(output) != nil else { return nil }
        let lines = output.split(separator: "\n").filter { !$0.hasPrefix("@@psh-") }
        let objects = lines.compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        switch kind {
        case .claude: return claudeTurns(objects)
        case .codex: return codexTurns(objects)
        }
    }

    static func claudeTurns(_ objects: [[String: Any]]) -> [AgentTurn] {
        var turns: [AgentTurn] = []
        var compacted = false
        for object in objects {
            guard object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                let message = object["message"] as? [String: Any]
            else { continue }
            if object["isCompactSummary"] as? Bool == true {
                compacted = true
                continue
            }
            switch object["type"] as? String {
            case "user":
                var text = message["content"] as? String
                if let items = message["content"] as? [[String: Any]] {
                    guard !items.contains(where: { $0["type"] as? String == "tool_result" }) else { continue }
                    text = items.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        .joined(separator: "\n")
                }
                guard let text, isPrompt(text) else { continue }
                turns.append(AgentTurn(prompt: text, time: object["timestamp"] as? String, afterCompaction: compacted))
                compacted = false
            case "assistant":
                for item in message["content"] as? [[String: Any]] ?? [] where item["type"] as? String == "text" {
                    guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !text.isEmpty
                    else { continue }
                    if turns.isEmpty { turns.append(AgentTurn(time: object["timestamp"] as? String)) }
                    turns[turns.count - 1].blocks.append(text)
                }
            default:
                break
            }
        }
        return turns
    }

    static func codexTurns(_ objects: [[String: Any]]) -> [AgentTurn] {
        var turns: [AgentTurn] = []
        var events: [[String]] = []
        var compacted = false
        func start(_ object: [String: Any], prompt: String? = nil) {
            turns.append(AgentTurn(prompt: prompt, time: object["timestamp"] as? String, afterCompaction: compacted))
            events.append([])
            compacted = false
        }
        for object in objects {
            if object["type"] as? String == "compacted" {
                compacted = true
                continue
            }
            guard let payload = object["payload"] as? [String: Any] else { continue }
            let fresh = turns.last.map { $0.prompt == nil && $0.blocks.isEmpty && $0.final == nil } ?? false
            switch (object["type"] as? String, payload["type"] as? String) {
            case ("event_msg", "task_started"):
                if !fresh { start(object) }
            case ("event_msg", "task_complete"):
                if let text = payload["last_agent_message"] as? String, !text.isEmpty, !turns.isEmpty {
                    turns[turns.count - 1].final = text
                }
            case ("event_msg", "user_message"):
                guard let text = payload["message"] as? String, isPrompt(text) else { continue }
                if fresh || turns.last?.prompt == text, !turns.isEmpty {
                    turns[turns.count - 1].prompt = text
                } else {
                    start(object, prompt: text)
                }
            case ("event_msg", "agent_message"):
                if let text = payload["message"] as? String, !text.isEmpty, !events.isEmpty {
                    events[events.count - 1].append(text)
                }
            case ("response_item", "message"):
                let items = payload["content"] as? [[String: Any]] ?? []
                let text = items.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                switch payload["role"] as? String {
                case "assistant" where !text.isEmpty:
                    if turns.isEmpty { start(object) }
                    turns[turns.count - 1].blocks.append(text)
                case "user" where isPrompt(text):
                    if turns.isEmpty { start(object) }
                    if turns[turns.count - 1].prompt == nil { turns[turns.count - 1].prompt = text }
                default:
                    break
                }
            default:
                break
            }
        }
        for index in turns.indices where turns[index].blocks.isEmpty { turns[index].blocks = events[index] }
        return turns
    }

    static func isPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("<") && !trimmed.hasPrefix("# AGENTS.md")
            && !trimmed.hasPrefix("Caveat:") && !trimmed.hasPrefix("[Request interrupted")
            && !trimmed.hasPrefix("[app:")
    }

    static let script = """
        \(HostAgents.path)
        kind=$1 pid=$2 root=$3 cwd=$4 n=${5:-1500} b=${6:-600000}
        if [ -z "$pid" ] && [ -n "$root" ]; then
        r=$(eval "$root" 2>/dev/null | head -n 1)
        case $r in ''|*[!0-9]*) r= ;; esac
        [ -n "$r" ] && pid=$(ps -A -o pid= -o ppid= -o args= | awk -v root="$r" '
        \(HostAgents.agentAwk)
        END { best = ""; depth = 99
        for (pid in kind) { d = 0; q = pid
        while (q != "" && q != root && d < 64) { q = parent[q]; d++ }
        if (q == root && d < depth) { depth = d; best = pid } }
        print best }')
        fi
        case $pid in *[!0-9]*) pid= ;; esac
        if [ -n "$pid" ] && [ -z "$cwd" ]; then
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
        fi
        f=
        if [ "$kind" = claude ]; then
        c="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
        s=
        [ -n "$pid" ] && s=$(sed -n 's/.*"sessionId":"\\([^"]*\\)".*/\\1/p' "$c/sessions/$pid.json" 2>/dev/null)
        if [ -n "$s" ]; then for t in "$c"/projects/*/"$s".jsonl; do [ -e "$t" ] && f=$t; break; done; fi
        if [ -z "$f" ] && [ -n "$cwd" ]; then
        f=$(ls -1t "$c/projects/$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"/*.jsonl 2>/dev/null | head -n 1)
        fi
        filter='"type":"(user|assistant)"'
        else
        d="${CODEX_HOME:-$HOME/.codex}/sessions"
        [ -n "$pid" ] && f=$(lsof -p "$pid" -Fn 2>/dev/null | sed -n 's/^n\\(.*rollout-.*\\.jsonl\\)$/\\1/p' | head -n 1)
        if [ -z "$f" ] && [ -n "$cwd" ]; then
        for t in $(find "$d" -name 'rollout-*.jsonl' -mtime -7 -exec ls -1t {} + 2>/dev/null | head -n 40); do
        head -n 1 "$t" | grep -qF "\\"cwd\\":\\"$cwd\\"" && { f=$t; break; }
        done
        fi
        filter='"type":"(task_started|task_complete|message|user_message|agent_message|compacted)"'
        fi
        [ -n "$f" ] && [ -r "$f" ] || { echo "@@psh-none@@"; exit 0; }
        echo "@@psh-file:$f@@"
        tail -n "$n" "$f" | grep -E "$filter" | awk '!/"isSidechain":true/ && !/"type":"tool_result"/ && !((/"type":"tool_use"/ || /"type":"thinking"/) && !/"type":"text"/)' | tail -c "$b"
        exit 0
        """
}
