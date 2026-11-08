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

public enum AgentTranscript {
    public static func command(kind: AgentKind, pid: Int?, rootCommand: String?, cwd: String?) -> String {
        let arguments = [kind.rawValue, pid.map(String.init) ?? "", rootCommand ?? "", cwd ?? ""]
        return "sh -c \(HostAgents.shellQuote(script)) sh "
            + arguments.map(HostAgents.shellQuote).joined(separator: " ")
    }

    public static func transcriptPath(_ output: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix("@@psh-file:") && $0.hasSuffix("@@") }.map {
            String($0.dropFirst(11).dropLast(2))
        }
    }

    public static func parse(kind: AgentKind, output: String) -> AgentAnswer? {
        guard transcriptPath(output) != nil else { return nil }
        let lines = output.split(separator: "\n").filter { !$0.hasPrefix("@@psh-") }
        let objects = lines.compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        switch kind {
        case .claude: return parseClaude(objects)
        case .codex: return parseCodex(objects)
        }
    }

    static func parseClaude(_ objects: [[String: Any]]) -> AgentAnswer {
        var answer = AgentAnswer(prompt: nil, blocks: [])
        for object in objects {
            guard object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                let message = object["message"] as? [String: Any]
            else { continue }
            switch object["type"] as? String {
            case "user":
                if let text = message["content"] as? String {
                    if isPrompt(text) { answer = AgentAnswer(prompt: text, blocks: []) }
                } else if let items = message["content"] as? [[String: Any]] {
                    guard !items.contains(where: { $0["type"] as? String == "tool_result" }) else { continue }
                    let text = items.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        .joined(separator: "\n")
                    if isPrompt(text) { answer = AgentAnswer(prompt: text, blocks: []) }
                }
            case "assistant":
                for item in message["content"] as? [[String: Any]] ?? [] where item["type"] as? String == "text" {
                    if let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !text.isEmpty
                    {
                        answer.blocks.append(text)
                    }
                }
            default:
                break
            }
        }
        return answer
    }

    static func parseCodex(_ objects: [[String: Any]]) -> AgentAnswer {
        var answer = AgentAnswer(prompt: nil, blocks: [])
        var events: [String] = []
        for object in objects {
            guard let payload = object["payload"] as? [String: Any] else { continue }
            let type = payload["type"] as? String
            switch (object["type"] as? String, type) {
            case ("event_msg", "task_started"):
                answer = AgentAnswer(prompt: nil, blocks: [])
                events = []
            case ("event_msg", "task_complete"):
                if let text = payload["last_agent_message"] as? String, !text.isEmpty { answer.final = text }
            case ("event_msg", "user_message"):
                if let text = payload["message"] as? String, isPrompt(text) {
                    answer = AgentAnswer(prompt: text, blocks: [])
                    events = []
                }
            case ("event_msg", "agent_message"):
                if let text = payload["message"] as? String, !text.isEmpty { events.append(text) }
            case ("response_item", "message"):
                let items = payload["content"] as? [[String: Any]] ?? []
                let text = items.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                switch payload["role"] as? String {
                case "assistant" where !text.isEmpty:
                    answer.blocks.append(text)
                case "user" where isPrompt(text) && answer.prompt == nil:
                    answer.prompt = text
                default:
                    break
                }
            default:
                break
            }
        }
        if answer.blocks.isEmpty { answer.blocks = events }
        return answer
    }

    static func isPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("<") && !trimmed.hasPrefix("# AGENTS.md")
            && !trimmed.hasPrefix("Caveat:") && !trimmed.hasPrefix("[Request interrupted")
    }

    static let script = """
        \(HostAgents.path)
        kind=$1 pid=$2 root=$3 cwd=$4
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
        filter='"type":"(task_started|task_complete|message|user_message|agent_message)"'
        fi
        [ -n "$f" ] && [ -r "$f" ] || { echo "@@psh-none@@"; exit 0; }
        echo "@@psh-file:$f@@"
        tail -n 1500 "$f" | grep -E "$filter" | tail -c 600000
        exit 0
        """
}
