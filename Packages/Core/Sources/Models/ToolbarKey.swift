import Foundation

public struct ToolbarKey: Identifiable, Codable, Hashable, Sendable {
    public enum Action: Codable, Hashable, Sendable {
        case escape
        case tab
        case ctrlModifier
        case arrowUp, arrowDown, arrowLeft, arrowRight
        case sequence(String)
    }

    public var id: UUID
    public var label: String
    public var action: Action

    public init(id: UUID = UUID(), label: String, action: Action) {
        self.id = id
        self.label = label
        self.action = action
    }

    public static func scrollRow(from keys: [ToolbarKey]) -> [ToolbarKey] {
        keys.filter { key in
            switch key.action {
            case .escape, .ctrlModifier, .arrowUp, .arrowDown, .arrowLeft, .arrowRight:
                false
            default:
                true
            }
        }
    }

    public static let defaults: [ToolbarKey] = [
        ToolbarKey(label: "esc", action: .escape),
        ToolbarKey(label: "ctrl", action: .ctrlModifier),
        ToolbarKey(label: "tab", action: .tab),
        ToolbarKey(label: "^C", action: .sequence("\u{03}")),
        ToolbarKey(label: "^D", action: .sequence("\u{04}")),
        ToolbarKey(label: "^Z", action: .sequence("\u{1a}")),
        ToolbarKey(label: "↑", action: .arrowUp),
        ToolbarKey(label: "↓", action: .arrowDown),
        ToolbarKey(label: "←", action: .arrowLeft),
        ToolbarKey(label: "→", action: .arrowRight),
        ToolbarKey(label: "C-b", action: .sequence("\u{02}")),
        ToolbarKey(label: "home", action: .sequence("\u{1b}[H")),
        ToolbarKey(label: "end", action: .sequence("\u{1b}[F")),
        ToolbarKey(label: "pgup", action: .sequence("\u{1b}[5~")),
        ToolbarKey(label: "pgdn", action: .sequence("\u{1b}[6~")),
        ToolbarKey(label: "/", action: .sequence("/")),
        ToolbarKey(label: "-", action: .sequence("-")),
    ]
}
