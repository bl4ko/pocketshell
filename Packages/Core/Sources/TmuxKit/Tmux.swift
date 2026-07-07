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

    public var id: String { name }

    public init(name: String, windows: Int, attached: Bool) {
        self.name = name
        self.windows = windows
        self.attached = attached
    }
}

public enum Tmux {
    static let tmux = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux"

    public static func listWindowsCommand(session: String) -> String {
        "\(tmux) list-windows -t \(shellQuote(session)) -F '#{window_index}|#{window_name}|#{window_active}'"
    }

    public static func listSessionsCommand() -> String {
        "\(tmux) list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}'"
    }

    public static func attachCommand(session: String, windowIndex: Int?) -> String {
        let attach = "\(tmux) attach-session -t \(shellQuote(session))"
        guard let windowIndex else { return attach }
        return "\(attach) \\; select-window -t \(windowIndex)"
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
            guard parts.count >= 3,
                  let windows = Int(parts[parts.count - 2]),
                  let attachedClients = Int(parts.last!)
            else { return nil }
            let name = parts[0..<(parts.count - 2)].joined(separator: "|")
            return TmuxSession(name: name, windows: windows, attached: attachedClients > 0)
        }
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
