import Foundation
import RoyalVNCKit

extension VNCKeyCode: @retroactive @unchecked Sendable {}

public struct VNCKeyCombo: Equatable, Identifiable, Sendable {
    public let modifiers: [VNCKeyCode]
    public let key: VNCKeyCode
    public let label: String

    public var id: String { label }

    public static let presets: [VNCKeyCombo] = [
        "cmd+space", "cmd+tab", "ctrl+left", "ctrl+right", "ctrl+up",
        "ctrl+cmd+f", "cmd+h", "cmd+w", "cmd+q", "cmd+m",
        "cmd+c", "cmd+v", "cmd+t", "cmd+n", "cmd+z", "cmd+a",
    ].compactMap(parse)

    public static func parse(_ text: String) -> VNCKeyCombo? {
        let tokens =
            text
            .lowercased()
            .split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyToken = tokens.last else { return nil }
        var modifiers: [VNCKeyCode] = []
        var labelParts: [String] = []
        for token in tokens.dropLast() {
            guard let modifier = modifierMap[token] else { return nil }
            modifiers.append(modifier.code)
            labelParts.append(modifier.symbol)
        }
        guard let key = keyFrom(keyToken) else { return nil }
        labelParts.append(key.label)
        return VNCKeyCombo(modifiers: modifiers, key: key.code, label: labelParts.joined())
    }

    private static let modifierMap: [String: (code: VNCKeyCode, symbol: String)] = [
        "cmd": (.commandForARD, "⌘"),
        "command": (.commandForARD, "⌘"),
        "meta": (.commandForARD, "⌘"),
        "shift": (.shift, "⇧"),
        "ctrl": (.control, "⌃"),
        "control": (.control, "⌃"),
        "alt": (.optionForARD, "⌥"),
        "opt": (.optionForARD, "⌥"),
        "option": (.optionForARD, "⌥"),
    ]

    private static let namedKeys: [String: (code: VNCKeyCode, label: String)] = {
        var keys: [String: (VNCKeyCode, String)] = [
            "space": (.space, "Space"),
            "tab": (.tab, "Tab"),
            "esc": (.escape, "Esc"),
            "escape": (.escape, "Esc"),
            "return": (.return, "Return"),
            "enter": (.return, "Return"),
            "delete": (.forwardDelete, "Del"),
            "backspace": (.delete, "⌫"),
            "up": (.upArrow, "↑"),
            "down": (.downArrow, "↓"),
            "left": (.leftArrow, "←"),
            "right": (.rightArrow, "→"),
            "home": (.home, "Home"),
            "end": (.end, "End"),
            "pageup": (.pageUp, "PgUp"),
            "pagedown": (.pageDown, "PgDn"),
        ]
        let fKeys: [VNCKeyCode] = [
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
            .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19,
        ]
        for (index, code) in fKeys.enumerated() {
            keys["f\(index + 1)"] = (code, "F\(index + 1)")
        }
        return keys
    }()

    private static func keyFrom(_ token: String) -> (code: VNCKeyCode, label: String)? {
        if let named = namedKeys[token] {
            return named
        }
        guard token.count == 1,
            let code = VNCKeyCode.keyCodesFrom(characters: token).first
        else {
            return nil
        }
        return (code, token.uppercased())
    }
}
