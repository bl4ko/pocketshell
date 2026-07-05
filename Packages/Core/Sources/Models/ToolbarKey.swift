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

    public static let defaults: [ToolbarKey] = [
        ToolbarKey(label: "esc", action: .escape),
        ToolbarKey(label: "ctrl", action: .ctrlModifier),
        ToolbarKey(label: "tab", action: .tab),
        ToolbarKey(label: "↑", action: .arrowUp),
        ToolbarKey(label: "↓", action: .arrowDown),
        ToolbarKey(label: "←", action: .arrowLeft),
        ToolbarKey(label: "→", action: .arrowRight),
        ToolbarKey(label: "C-b", action: .sequence("\u{02}")),
    ]
}
