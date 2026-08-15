import Foundation
import Models

public struct ShortcutChip: Identifiable, Hashable, Sendable {
    public let glyph: String
    public let label: String
    public let action: ToolbarKey.Action

    public init(glyph: String, label: String, action: ToolbarKey.Action) {
        self.glyph = glyph
        self.label = label
        self.action = action
    }

    public var id: String { "\(glyph)|\(label)" }
}

public enum ShortcutCategory: String, CaseIterable, Sendable {
    case favorites
    case shell
    case agent
    case multiplexer

    public var icon: String {
        switch self {
        case .favorites: "star"
        case .shell: "chevron.left.forwardslash.chevron.right"
        case .agent: "sparkles"
        case .multiplexer: "square.grid.2x2"
        }
    }
}

public enum ShortcutCatalog {
    public static let tmuxPrefix = "\u{02}"

    public static func categories(multiplexer: Bool) -> [ShortcutCategory] {
        multiplexer ? ShortcutCategory.allCases : [.favorites, .shell, .agent]
    }

    public static func chips(
        _ category: ShortcutCategory,
        userKeys: [ToolbarKey] = [],
        prefix: String = tmuxPrefix
    ) -> [ShortcutChip] {
        switch category {
        case .favorites: favorites(userKeys)
        case .shell: shell
        case .agent: agent
        case .multiplexer: multiplexer(prefix)
        }
    }

    private static func favorites(_ userKeys: [ToolbarKey]) -> [ShortcutChip] {
        ToolbarKey.scrollRow(from: userKeys).map {
            ShortcutChip(glyph: $0.label, label: name(for: $0.action), action: $0.action)
        }
    }

    private static let shell: [ShortcutChip] = [
        ShortcutChip(glyph: "^C", label: "interrupt", action: .sequence("\u{03}")),
        ShortcutChip(glyph: "^D", label: "eof", action: .sequence("\u{04}")),
        ShortcutChip(glyph: "^Z", label: "suspend", action: .sequence("\u{1a}")),
        ShortcutChip(glyph: "^L", label: "clear", action: .sequence("\u{0c}")),
        ShortcutChip(glyph: "^R", label: "search", action: .sequence("\u{12}")),
        ShortcutChip(glyph: "^A", label: "line start", action: .sequence("\u{01}")),
        ShortcutChip(glyph: "^E", label: "line end", action: .sequence("\u{05}")),
        ShortcutChip(glyph: "^W", label: "del word", action: .sequence("\u{17}")),
        ShortcutChip(glyph: "^U", label: "kill line", action: .sequence("\u{15}")),
        ShortcutChip(glyph: "^K", label: "kill right", action: .sequence("\u{0b}")),
        ShortcutChip(glyph: "pgup", label: "page up", action: .sequence("\u{1b}[5~")),
        ShortcutChip(glyph: "pgdn", label: "page down", action: .sequence("\u{1b}[6~")),
    ]

    private static let agent: [ShortcutChip] = [
        ShortcutChip(glyph: "/clear", label: "reset", action: .sequence("/clear\r")),
        ShortcutChip(glyph: "/compact", label: "shrink", action: .sequence("/compact\r")),
        ShortcutChip(glyph: "/resume", label: "continue", action: .sequence("/resume\r")),
        ShortcutChip(glyph: "/model", label: "switch", action: .sequence("/model\r")),
        ShortcutChip(glyph: "/cost", label: "usage", action: .sequence("/cost\r")),
        ShortcutChip(glyph: "/context", label: "window", action: .sequence("/context\r")),
        ShortcutChip(glyph: "⇧⇥", label: "mode", action: .sequence("\u{1b}[Z")),
        ShortcutChip(glyph: "esc esc", label: "rewind", action: .sequence("\u{1b}\u{1b}")),
        ShortcutChip(glyph: "1↵", label: "yes", action: .sequence("1\r")),
        ShortcutChip(glyph: "2↵", label: "no", action: .sequence("2\r")),
    ]

    private static func multiplexer(_ prefix: String) -> [ShortcutChip] {
        [
            ("c", "new win"), ("n", "next"), ("p", "prev"), ("d", "detach"),
            ("z", "zoom"), ("%", "split"), ("\"", "stack"), ("o", "pane"),
            ("[", "scroll"), ("w", "windows"), (",", "rename"), ("x", "close"),
        ].map { key, label in
            ShortcutChip(glyph: "^b,\(key)", label: label, action: .sequence(prefix + key))
        }
    }

    public static func windowChips(_ count: Int = 9, prefix: String = tmuxPrefix) -> [ShortcutChip] {
        (0..<count).map {
            ShortcutChip(glyph: "\($0)", label: "", action: .sequence(prefix + "\($0)"))
        }
    }

    private static func name(for action: ToolbarKey.Action) -> String {
        switch action {
        case .sequence(let value): shell.first { $0.action == .sequence(value) }?.label ?? ""
        default: ""
        }
    }
}
