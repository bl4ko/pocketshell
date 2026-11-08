import Foundation
import HerdrKit
import MonitorKit
import TmuxKit

public enum AgentKey: String, Equatable, Sendable, CaseIterable {
    case esc
    case ctrlC = "ctrl_c"
    case enter
}

public enum AgentControl {
    static let tmux = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux"

    public static func promptCommand(_ agent: BrainAgent, text: String) -> String {
        let line = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        switch agent.location {
        case .tmux(_, _, _, let pane):
            let target = HostAgents.shellQuote(pane)
            return "\(tmux) send-keys -t \(target) -l -- \(HostAgents.shellQuote(line))"
                + " && sleep 0.3 && \(tmux) send-keys -t \(target) Enter"
        case .herdr(let session, let pane, _, _):
            return "\(Herdr.commandPrefix(session: session)) agent prompt \(HostAgents.shellQuote(pane))"
                + " \(HostAgents.shellQuote(line)) 2>&1 || true"
        }
    }

    public static func keyCommand(_ agent: BrainAgent, key: AgentKey) -> String {
        switch agent.location {
        case .tmux(_, _, _, let pane):
            let name =
                switch key {
                case .esc: "Escape"
                case .ctrlC: "C-c"
                case .enter: "Enter"
                }
            return "\(tmux) send-keys -t \(HostAgents.shellQuote(pane)) \(name)"
        case .herdr(let session, let pane, _, _):
            let name =
                switch key {
                case .esc: "esc"
                case .ctrlC: "ctrl+c"
                case .enter: "enter"
                }
            return "\(Herdr.commandPrefix(session: session)) agent send-keys \(HostAgents.shellQuote(pane)) \(name)"
                + " 2>&1 || true"
        }
    }

    public static func textCommand(_ agent: BrainAgent, text: String) -> String {
        switch agent.location {
        case .tmux(_, _, _, let pane):
            return "\(tmux) send-keys -t \(HostAgents.shellQuote(pane)) -l -- \(HostAgents.shellQuote(text))"
        case .herdr(let session, let pane, _, _):
            return "\(Herdr.commandPrefix(session: session)) pane send-text \(HostAgents.shellQuote(pane))"
                + " \(HostAgents.shellQuote(text)) 2>&1 || true"
        }
    }

    public static func screenCommand(_ agent: BrainAgent) -> String {
        switch agent.location {
        case .tmux(_, _, _, let pane):
            return "\(tmux) capture-pane -p -t \(HostAgents.shellQuote(pane))"
        case .herdr(let session, let pane, _, _):
            return "\(Herdr.commandPrefix(session: session)) pane read \(HostAgents.shellQuote(pane)) --source visible"
        }
    }

    public static func boxCommand(_ agent: BrainAgent) -> String {
        switch agent.location {
        case .tmux(_, _, _, let pane):
            return "\(tmux) capture-pane -p -e -t \(HostAgents.shellQuote(pane))"
        case .herdr(let session, let pane, _, _):
            return Herdr.paneReadCommand(session: session, paneID: pane)
        }
    }

    public static func unsentPrompt(fromBox output: String) -> String? {
        guard let box = UnsentPrompt.read(screenLines: UnsentPrompt.plainLines(ansi: output)), !box.text.isEmpty
        else { return nil }
        return box.text
    }

    public static func exitCommand(_ agent: BrainAgent) -> String {
        let key = keyCommand(agent, key: .ctrlC)
        return "\(key); sleep 0.3; \(key)"
    }

    public static func startCommand(kind: AgentKind, tmuxSession: String, directory: String?) -> String {
        let window =
            "\(tmux) new-window -t \(HostAgents.shellQuote(tmuxSession))"
            + (directory.map { " -c \(HostAgents.shellQuote($0))" } ?? "")
            + " -P -F '#{pane_id}'"
        return "p=$(\(window)) && sleep 0.5 && \(tmux) send-keys -t \"$p\" -l -- \(kind.rawValue)"
            + " && \(tmux) send-keys -t \"$p\" Enter && echo \"$p\""
    }

    public static func transcriptCommand(_ agent: BrainAgent) -> String {
        switch agent.location {
        case .tmux:
            return AgentTranscript.command(kind: agent.kind, pid: agent.pid, rootCommand: nil, cwd: agent.cwd)
        case .herdr(let session, let pane, _, _):
            return AgentTranscript.command(
                kind: agent.kind, pid: agent.pid,
                rootCommand: Herdr.paneShellPIDCommand(session: session, paneID: pane), cwd: agent.cwd)
        }
    }

    public static func checked(_ command: String) -> String {
        "( \(command) ) 2>&1; printf '\\n@@psh-exit:%s@@' \"$?\""
    }

    public static func splitExit(_ output: String) -> (output: String, status: Int) {
        guard let range = output.range(of: "\n@@psh-exit:", options: .backwards),
            let status = Int(output[range.upperBound...].prefix { $0.isNumber })
        else { return (output, 0) }
        let body = output[..<range.lowerBound]
        return (String(body.hasSuffix("\n") ? body.dropLast() : body), status)
    }

    public static func herdrFailure(_ output: String) -> String? {
        guard output.contains("\"error\"") || output.contains("\"code\"") else { return nil }
        if let range = output.range(of: "\"message\":\"([^\"]*)\"", options: .regularExpression) {
            return String(output[range].dropFirst(11).dropLast())
        }
        return "Herdr rejected the request"
    }

    public static func optionDigit(_ option: String, screen: String?) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let digit = Int(trimmed), (1...9).contains(digit) { return String(digit) }
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
        if let digit = words[trimmed] { return String(digit) }
        if let digit = trimmed.firstMatch(of: /^(?:option|number)\s+([1-9])$/)?.1 { return String(digit) }
        guard let screen, !trimmed.isEmpty else { return nil }
        for line in screen.split(separator: "\n").reversed() {
            guard let match = line.firstMatch(of: /([1-9])[.)]\s+(.+)/) else { continue }
            if match.2.lowercased().contains(trimmed) { return String(match.1) }
        }
        return nil
    }

    public static func optionLabel(_ digit: String, screen: String?) -> String? {
        guard let screen else { return nil }
        for line in screen.split(separator: "\n").reversed() {
            guard let match = line.firstMatch(of: /([1-9])[.)]\s+(.+)/), String(match.1) == digit else { continue }
            return match.2.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
