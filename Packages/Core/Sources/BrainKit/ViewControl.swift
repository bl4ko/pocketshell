import Foundation

public enum ViewAction: String, Equatable, Sendable, CaseIterable {
    case bottom
    case pageUp = "page_up"
    case pageDown = "page_down"
    case top
    case showKeyboard = "show_keyboard"
    case hideKeyboard = "hide_keyboard"
    case showShortcuts = "show_shortcuts"
    case hideShortcuts = "hide_shortcuts"
    case focusModeOn = "focus_mode_on"
    case focusModeOff = "focus_mode_off"
    case fontBigger = "font_bigger"
    case fontSmaller = "font_smaller"
    case fontReset = "font_reset"

    public var acknowledgement: String {
        switch self {
        case .bottom, .pageDown: "Scrolled down."
        case .pageUp: "Scrolled up."
        case .top: "At the top."
        case .showKeyboard: "Keyboard's up."
        case .hideKeyboard: "Keyboard's away."
        case .showShortcuts: "Shortcuts are up."
        case .hideShortcuts: "Shortcuts are away."
        case .focusModeOn: "Focus mode's on."
        case .focusModeOff: "Focus mode's off."
        case .fontBigger: "Bigger."
        case .fontSmaller: "Smaller."
        case .fontReset: "Font's reset."
        }
    }
}

extension SessionToolbox {
    func view(_ arguments: [String: Any], target: String?, refresh: @MainActor () async -> Void) async -> Outcome {
        guard let action = ViewAction(rawValue: (arguments["action"] as? String ?? "").lowercased()) else {
            return .done(
                Self.error("action must be one of " + ViewAction.allCases.map(\.rawValue).joined(separator: ", ")))
        }
        let pages = min(20, max(1, (arguments["pages"] as? NSNumber)?.intValue ?? 1))
        guard let target else { return .done(await apply(action, pages: pages)) }
        if !ingested { await refresh() }
        return await withTarget(target, refresh: refresh) { session in
            if !session.isCurrent {
                let shown = await self.focus(session)
                if AgentToolbox.failure(shown) != nil { return .done(shown) }
            }
            return .done(await self.apply(action, pages: pages))
        }
    }

    private func apply(_ action: ViewAction, pages: Int) async -> String {
        if let failure = await io.view(action, pages) { return Self.error(failure) }
        return AgentToolbox.done(action.acknowledgement)
    }

    nonisolated static let viewDefinition = ToolDefinition(
        name: "view",
        description:
            "Move the phone's view of a tab without typing anything into it: scroll back down to the live input box "
            + "(bottom), up or down by pages, or to the top; show or hide the keyboard or the shortcut panel; turn "
            + "Herdr focus mode on or off; make the font bigger or smaller, or reset it.",
        parameters: .object([
            "type": "object",
            "properties": .object([
                "action": .object([
                    "type": "string", "enum": .array(ViewAction.allCases.map { .string($0.rawValue) }),
                    "description": "bottom also means \"scroll down to the input\" or \"back to the prompt\".",
                ]),
                "pages": .object(["type": "integer", "description": "Pages for page_up and page_down. Default 1."]),
                "target": targetParameter,
            ]),
            "required": .array(["action"]),
        ]))

    nonisolated public static let viewPrompt = """
        You can also move the phone's view with the view tool: scroll a tab back to its input box, page up or down, \
        show the keyboard or the shortcut panel, turn Herdr focus mode on or off, and change the font size. It \
        types nothing, so it never needs a confirmation.
        """
}
