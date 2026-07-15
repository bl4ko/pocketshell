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

    static let waitingMarkers = [
        "do you want",
        "would you like to run",
        "yes, proceed",
        "allow once",
        "allow always",
        "press enter to confirm",
    ]

    static let agentMarkers = [
        "? for shortcuts",
        "bypass permissions",
        "accept edits",
        "plan mode on",
        "shift+tab to cycle",
        "esc to interrupt",
        "compacting conversation",
    ]

    public static func detectAgent(_ paneText: String) -> AgentStatus? {
        let status = classify(paneText)
        if status != .idle { return status }
        let lowered = paneText.lowercased()
        if agentMarkers.contains(where: lowered.contains) { return .idle }
        if lowered.contains(/\d+% (context left|used)/) { return .idle }
        return nil
    }

    public static func classify(_ paneText: String) -> AgentStatus {
        var lines = paneText.split(separator: "\n", omittingEmptySubsequences: false)
        while lines.last?.allSatisfy(\.isWhitespace) == true {
            lines.removeLast()
        }
        let tail = lines.suffix(15).joined(separator: "\n")
        let lowered = tail.lowercased()
        if lowered.contains("compacting conversation") || lowered.contains(/esc\b.{0,12}interrupt/) {
            return .busy
        }
        if tail.contains(/\p{L}…\s*\(\d+[hms]/) {
            return .busy
        }
        if waitingMarkers.contains(where: lowered.contains) {
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

    public static func cloneName(session: String, clientTag: String) -> String {
        "\(session)-psh-\(clientTag)"
    }

    public static func currentWindowCommand(clone: String) -> String {
        "\(tmux) display-message -p -t \(shellQuote(clone)) '#{window_index}'"
    }

    public static func parseCurrentWindow(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func attachCommand(session: String, windowIndex: Int?, clientTag: String) -> String {
        let clone = cloneName(session: session, clientTag: clientTag)
        let attach =
            "\(tmux) -u new-session -t \(shellQuote(session)) -s \(shellQuote(clone))"
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

    public static func capturePanesCommand(session: String) -> String {
        let target = shellQuote(session)
        return
            "for w in $(\(tmux) list-windows -t \(target) -F '#{window_index}'); do echo \"@@pane:$w@@\"; \(tmux) capture-pane -p -t \(target):$w; done"
    }

    public static func reorderWindowsCommand(session: String, indexes: [Int], fromOffset: Int, toOffset: Int) -> String?
    {
        guard fromOffset >= 0, fromOffset < indexes.count, toOffset >= 0, toOffset <= indexes.count else { return nil }
        let dest = toOffset > fromOffset ? toOffset - 1 : toOffset
        guard dest != fromOffset else { return nil }
        let target = shellQuote(session)
        var swaps: [String] = []
        if dest > fromOffset {
            for position in fromOffset..<dest {
                swaps.append("swap-window -d -s \(target):\(indexes[position]) -t \(target):\(indexes[position + 1])")
            }
        } else {
            for position in stride(from: fromOffset, to: dest, by: -1) {
                swaps.append("swap-window -d -s \(target):\(indexes[position]) -t \(target):\(indexes[position - 1])")
            }
        }
        return "\(tmux) " + swaps.joined(separator: " \\; ")
    }

    public static func orderSessions(_ sessions: [TmuxSession], by saved: [String]) -> [TmuxSession] {
        guard !saved.isEmpty else { return sessions }
        let positions = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return sessions.enumerated()
            .sorted {
                (positions[$0.element.name] ?? saved.count + $0.offset)
                    < (positions[$1.element.name] ?? saved.count + $1.offset)
            }
            .map(\.element)
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
                let index = Int(line.dropFirst(7).dropLast(2))
            {
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

    public static func dropStatusLine(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while lines.last?.allSatisfy(\.isWhitespace) == true { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        lines.removeLast()
        return lines.joined(separator: "\n")
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

    public static func newSessionCommand(name: String) -> String {
        "\(tmux) new-session -d -s \(shellQuote(name))"
    }

    public static func renameWindowCommand(session: String, windowIndex: Int, name: String) -> String {
        "\(tmux) rename-window -t \(shellQuote(session)):\(windowIndex) \(shellQuote(name))"
    }

    public static func renameSessionCommand(from oldName: String, to newName: String) -> String {
        "\(tmux) rename-session -t \(shellQuote(oldName)) \(shellQuote(newName))"
    }

    public static func killSessionCommand(name: String) -> String {
        "\(tmux) kill-session -t \(shellQuote(name))"
    }

    public static func killWindowCommand(session: String, windowIndex: Int) -> String {
        "\(tmux) kill-window -t \(shellQuote(session)):\(windowIndex)"
    }

    public static let nextPaneKeys = "\u{02}o"
    public static let zoomPaneKeys = "\u{02}z"
    public static let nextWindowKeys = "\u{02}n"
    public static let previousWindowKeys = "\u{02}p"
    public static let newWindowKeys = "\u{02}c"
    public static let splitHorizontalKeys = "\u{02}%"
    public static let splitVerticalKeys = "\u{02}\""

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
