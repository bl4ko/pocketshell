import Foundation
import GhosttyVt

public struct VTModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let shift = VTModifiers(rawValue: 1 << 0)
    public static let control = VTModifiers(rawValue: 1 << 1)
    public static let alt = VTModifiers(rawValue: 1 << 2)
    public static let command = VTModifiers(rawValue: 1 << 3)
    public static let capsLock = VTModifiers(rawValue: 1 << 4)
}

public struct VTKey: Hashable, Sendable {
    let raw: GhosttyKey

    init(_ raw: GhosttyKey) {
        self.raw = raw
    }

    public static let up = VTKey(GHOSTTY_KEY_ARROW_UP)
    public static let down = VTKey(GHOSTTY_KEY_ARROW_DOWN)
    public static let left = VTKey(GHOSTTY_KEY_ARROW_LEFT)
    public static let right = VTKey(GHOSTTY_KEY_ARROW_RIGHT)
    public static let enter = VTKey(GHOSTTY_KEY_ENTER)
    public static let escape = VTKey(GHOSTTY_KEY_ESCAPE)
    public static let tab = VTKey(GHOSTTY_KEY_TAB)
    public static let backspace = VTKey(GHOSTTY_KEY_BACKSPACE)
    public static let space = VTKey(GHOSTTY_KEY_SPACE)

    public init?(hidUsage: Int) {
        switch hidUsage {
        case 0x04...0x1d:
            self.init(GhosttyKey(rawValue: GHOSTTY_KEY_A.rawValue + Int32(hidUsage - 0x04)))
        case 0x1e...0x26:
            self.init(GhosttyKey(rawValue: GHOSTTY_KEY_DIGIT_1.rawValue + Int32(hidUsage - 0x1e)))
        case 0x3a...0x45:
            self.init(GhosttyKey(rawValue: GHOSTTY_KEY_F1.rawValue + Int32(hidUsage - 0x3a)))
        case 0x68...0x73:
            self.init(GhosttyKey(rawValue: GHOSTTY_KEY_F13.rawValue + Int32(hidUsage - 0x68)))
        case 0x59...0x61:
            self.init(GhosttyKey(rawValue: GHOSTTY_KEY_NUMPAD_1.rawValue + Int32(hidUsage - 0x59)))
        default:
            guard let key = Self.table[hidUsage] else { return nil }
            self.init(key)
        }
    }

    private static let table: [Int: GhosttyKey] = [
        0x27: GHOSTTY_KEY_DIGIT_0, 0x28: GHOSTTY_KEY_ENTER, 0x29: GHOSTTY_KEY_ESCAPE,
        0x2a: GHOSTTY_KEY_BACKSPACE, 0x2b: GHOSTTY_KEY_TAB, 0x2c: GHOSTTY_KEY_SPACE,
        0x2d: GHOSTTY_KEY_MINUS, 0x2e: GHOSTTY_KEY_EQUAL, 0x2f: GHOSTTY_KEY_BRACKET_LEFT,
        0x30: GHOSTTY_KEY_BRACKET_RIGHT, 0x31: GHOSTTY_KEY_BACKSLASH, 0x33: GHOSTTY_KEY_SEMICOLON,
        0x34: GHOSTTY_KEY_QUOTE, 0x35: GHOSTTY_KEY_BACKQUOTE, 0x36: GHOSTTY_KEY_COMMA,
        0x37: GHOSTTY_KEY_PERIOD, 0x38: GHOSTTY_KEY_SLASH, 0x39: GHOSTTY_KEY_CAPS_LOCK,
        0x46: GHOSTTY_KEY_PRINT_SCREEN, 0x47: GHOSTTY_KEY_SCROLL_LOCK, 0x48: GHOSTTY_KEY_PAUSE,
        0x49: GHOSTTY_KEY_INSERT, 0x4a: GHOSTTY_KEY_HOME, 0x4b: GHOSTTY_KEY_PAGE_UP,
        0x4c: GHOSTTY_KEY_DELETE, 0x4d: GHOSTTY_KEY_END, 0x4e: GHOSTTY_KEY_PAGE_DOWN,
        0x4f: GHOSTTY_KEY_ARROW_RIGHT, 0x50: GHOSTTY_KEY_ARROW_LEFT, 0x51: GHOSTTY_KEY_ARROW_DOWN,
        0x52: GHOSTTY_KEY_ARROW_UP, 0x53: GHOSTTY_KEY_NUM_LOCK, 0x54: GHOSTTY_KEY_NUMPAD_DIVIDE,
        0x55: GHOSTTY_KEY_NUMPAD_MULTIPLY, 0x56: GHOSTTY_KEY_NUMPAD_SUBTRACT, 0x57: GHOSTTY_KEY_NUMPAD_ADD,
        0x58: GHOSTTY_KEY_NUMPAD_ENTER, 0x62: GHOSTTY_KEY_NUMPAD_0, 0x63: GHOSTTY_KEY_NUMPAD_DECIMAL,
        0x64: GHOSTTY_KEY_INTL_BACKSLASH, 0x65: GHOSTTY_KEY_CONTEXT_MENU, 0x67: GHOSTTY_KEY_NUMPAD_EQUAL,
        0xe0: GHOSTTY_KEY_CONTROL_LEFT, 0xe1: GHOSTTY_KEY_SHIFT_LEFT, 0xe2: GHOSTTY_KEY_ALT_LEFT,
        0xe3: GHOSTTY_KEY_META_LEFT, 0xe4: GHOSTTY_KEY_CONTROL_RIGHT, 0xe5: GHOSTTY_KEY_SHIFT_RIGHT,
        0xe6: GHOSTTY_KEY_ALT_RIGHT, 0xe7: GHOSTTY_KEY_META_RIGHT,
    ]

    public var isModifier: Bool {
        [
            GHOSTTY_KEY_CONTROL_LEFT, GHOSTTY_KEY_CONTROL_RIGHT, GHOSTTY_KEY_SHIFT_LEFT, GHOSTTY_KEY_SHIFT_RIGHT,
            GHOSTTY_KEY_ALT_LEFT, GHOSTTY_KEY_ALT_RIGHT, GHOSTTY_KEY_META_LEFT, GHOSTTY_KEY_META_RIGHT,
            GHOSTTY_KEY_CAPS_LOCK,
        ].contains(raw)
    }
}

public enum VTKeyAction: Sendable {
    case press
    case repeatPress
    case release
}

extension VTTerminal {
    public func encodeKey(
        _ key: VTKey, modifiers: VTModifiers = [], text: String? = nil, unshifted: Character? = nil,
        action: VTKeyAction = .press
    ) -> [UInt8] {
        guard let keyEncoder, let keyEvent else { return [] }
        ghostty_key_encoder_setopt_from_terminal(keyEncoder, handle)
        var optionAsAlt = GHOSTTY_OPTION_AS_ALT_TRUE
        ghostty_key_encoder_setopt(keyEncoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionAsAlt)
        ghostty_key_event_set_key(keyEvent, key.raw)
        ghostty_key_event_set_mods(keyEvent, GhosttyMods(modifiers.rawValue))
        ghostty_key_event_set_consumed_mods(keyEvent, 0)
        ghostty_key_event_set_composing(keyEvent, false)
        switch action {
        case .press: ghostty_key_event_set_action(keyEvent, GHOSTTY_KEY_ACTION_PRESS)
        case .repeatPress: ghostty_key_event_set_action(keyEvent, GHOSTTY_KEY_ACTION_REPEAT)
        case .release: ghostty_key_event_set_action(keyEvent, GHOSTTY_KEY_ACTION_RELEASE)
        }
        ghostty_key_event_set_unshifted_codepoint(keyEvent, unshifted?.unicodeScalars.first?.value ?? 0)
        let utf8 = Array((text ?? "").utf8)
        var output = [CChar](repeating: 0, count: 128)
        var written = 0
        let result = utf8.withUnsafeBufferPointer { textBuffer in
            textBuffer.withMemoryRebound(to: CChar.self) { chars in
                ghostty_key_event_set_utf8(keyEvent, chars.baseAddress, chars.count)
                return output.withUnsafeMutableBufferPointer {
                    ghostty_key_encoder_encode(keyEncoder, keyEvent, $0.baseAddress, $0.count, &written)
                }
            }
        }
        ghostty_key_event_set_utf8(keyEvent, nil, 0)
        guard result == GHOSTTY_SUCCESS else { return [] }
        return output.prefix(written).map { UInt8(bitPattern: $0) }
    }

    public func encodeMouse(
        button: VTMouseButton?, action: VTMouseAction, col: Int, row: Int, modifiers: VTModifiers = []
    ) -> [UInt8] {
        guard let mouseEncoder, let mouseEvent else { return [] }
        ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, handle)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.cell_width = cellPixels.width
        size.cell_height = cellPixels.height
        size.screen_width = UInt32(cols) * cellPixels.width
        size.screen_height = UInt32(rows) * cellPixels.height
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        switch action {
        case .press: ghostty_mouse_event_set_action(mouseEvent, GHOSTTY_MOUSE_ACTION_PRESS)
        case .release: ghostty_mouse_event_set_action(mouseEvent, GHOSTTY_MOUSE_ACTION_RELEASE)
        case .motion: ghostty_mouse_event_set_action(mouseEvent, GHOSTTY_MOUSE_ACTION_MOTION)
        }
        switch button {
        case .left: ghostty_mouse_event_set_button(mouseEvent, GHOSTTY_MOUSE_BUTTON_LEFT)
        case .middle: ghostty_mouse_event_set_button(mouseEvent, GHOSTTY_MOUSE_BUTTON_MIDDLE)
        case .right: ghostty_mouse_event_set_button(mouseEvent, GHOSTTY_MOUSE_BUTTON_RIGHT)
        case .wheelUp: ghostty_mouse_event_set_button(mouseEvent, GHOSTTY_MOUSE_BUTTON_FOUR)
        case .wheelDown: ghostty_mouse_event_set_button(mouseEvent, GHOSTTY_MOUSE_BUTTON_FIVE)
        case nil: ghostty_mouse_event_clear_button(mouseEvent)
        }
        var pressed = action == .motion && button != nil
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
        ghostty_mouse_event_set_mods(mouseEvent, GhosttyMods(modifiers.rawValue))
        ghostty_mouse_event_set_position(
            mouseEvent,
            GhosttyMousePosition(
                x: (Float(col) + 0.5) * Float(cellPixels.width), y: (Float(row) + 0.5) * Float(cellPixels.height)))
        var output = [CChar](repeating: 0, count: 64)
        var written = 0
        let result = output.withUnsafeMutableBufferPointer {
            ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, $0.baseAddress, $0.count, &written)
        }
        guard result == GHOSTTY_SUCCESS else { return [] }
        return output.prefix(written).map { UInt8(bitPattern: $0) }
    }

    public func encodeFocus(_ gained: Bool) -> [UInt8] {
        var output = [CChar](repeating: 0, count: 8)
        var written = 0
        let result = output.withUnsafeMutableBufferPointer {
            ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, $0.baseAddress, $0.count, &written)
        }
        guard result == GHOSTTY_SUCCESS else { return [] }
        return output.prefix(written).map { UInt8(bitPattern: $0) }
    }
}
