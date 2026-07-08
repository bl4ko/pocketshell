import Foundation

public struct TmuxWindow: Equatable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var name: String
    public var active: Bool

    public var id: Int { index }

    public init(index: Int, name: String, active: Bool) {
        self.index = index
        self.name = name
        self.active = active
    }
}

public struct TmuxSession: Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var windows: Int
    public var attached: Bool
    public var group: String?

    public var id: String { name }

    public init(name: String, windows: Int, attached: Bool, group: String? = nil) {
        self.name = name
        self.windows = windows
        self.attached = attached
        self.group = group
    }
}

public enum AgentStatus: Equatable, Sendable {
    case busy
    case waiting
    case idle

    public static func classify(_ paneText: String) -> AgentStatus {
        let lowered = paneText.lowercased()
        if lowered.contains("esc to interrupt") || lowered.contains("compacting conversation") {
            return .busy
        }
        if paneText.contains(/\p{L}…\s*\(\d+[hms]/) {
            return .busy
        }
        if paneText.contains("Do you want") {
            return .waiting
        }
        return .idle
    }
}

public enum Tmux {
    static let tmux = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux"

    public static func listWindowsCommand(session: String) -> String {
        "\(tmux) list-windows -t \(shellQuote(session)) -F '#{window_index}|#{window_name}|#{window_active}'"
    }

    public static func listSessionsCommand() -> String {
        "\(tmux) list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}|#{session_group}'"
    }

    public static func attachCommand(session: String, windowIndex: Int?, clientTag: String) -> String {
        let clone = "\(session)-psh-\(clientTag)"
        let attach = "\(tmux) -u new-session -t \(shellQuote(session)) -s \(shellQuote(clone))"
            + " \\; set-option destroy-unattached on"
        guard let windowIndex else { return attach }
        return "\(attach) \\; select-window -t \(windowIndex)"
    }

    public static func sendKeysCommand(session: String, windowIndex: Int, text: String, pressEnter: Bool) -> String {
        let target = "\(shellQuote(session)):\(windowIndex)"
        let send = "\(tmux) send-keys -t \(target) -l \(shellQuote(text))"
        guard pressEnter else { return send }
        return "\(send) \\; send-keys -t \(target) Enter"
    }

    public static func capturePanesCommand(session: String, lines: Int) -> String {
        let target = shellQuote(session)
        return "for w in $(\(tmux) list-windows -t \(target) -F '#{window_index}'); do echo \"@@pane:$w@@\"; \(tmux) capture-pane -p -t \(target):$w -S -\(lines); done"
    }

    public static func parsePaneCaptures(_ output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var current: Int?
        var lines: [String] = []
        func flush() {
            guard let index = current else { return }
            var text = lines
            while text.last?.isEmpty == true {
                text.removeLast()
            }
            result[index] = text.joined(separator: "\n")
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@pane:"), line.hasSuffix("@@"),
               let index = Int(line.dropFirst(7).dropLast(2)) {
                flush()
                current = index
                lines = []
            } else if current != nil {
                lines.append(String(line))
            }
        }
        flush()
        return result
    }

    public static func previewLines(_ text: String, count: Int) -> String {
        text.split(separator: "\n")
            .filter { line in line.contains { $0.isLetter || $0.isNumber } }
            .suffix(count)
            .joined(separator: "\n")
    }

    public static func parseWindows(_ output: String) -> [TmuxWindow] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 3,
                  let index = Int(parts[0]),
                  let active = flag(parts.last!)
            else { return nil }
            let name = parts[1..<(parts.count - 1)].joined(separator: "|")
            return TmuxWindow(index: index, name: name, active: active)
        }
    }

    public static func parseSessions(_ output: String) -> [TmuxSession] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 4,
                  let windows = Int(parts[parts.count - 3]),
                  let attachedClients = Int(parts[parts.count - 2])
            else { return nil }
            let name = parts[0..<(parts.count - 3)].joined(separator: "|")
            let group = parts.last!.isEmpty ? nil : String(parts.last!)
            return TmuxSession(name: name, windows: windows, attached: attachedClients > 0, group: group)
        }
    }

    public static func consolidateGroups(_ sessions: [TmuxSession]) -> [TmuxSession] {
        var order: [String] = []
        var merged: [String: TmuxSession] = [:]
        for session in sessions {
            let key = session.group ?? session.name
            if var existing = merged[key] {
                existing.attached = existing.attached || session.attached
                if session.name == key {
                    existing.name = session.name
                    existing.windows = session.windows
                }
                merged[key] = existing
            } else {
                order.append(key)
                merged[key] = session
            }
        }
        return order.compactMap { merged[$0] }
    }

    public static let nextPaneKeys = "\u{02}o"
    public static let zoomPaneKeys = "\u{02}z"
    public static let nextWindowKeys = "\u{02}n"
    public static let previousWindowKeys = "\u{02}p"

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func flag(_ value: Substring) -> Bool? {
        switch value {
        case "0": false
        case "1": true
        default: nil
        }
    }
}
