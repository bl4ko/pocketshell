import Foundation
import Models

public enum ToolbarKeyEncoder {
    public static func data(
        for action: ToolbarKey.Action, shift: Bool = false, applicationCursor: Bool = false
    ) -> Data? {
        let arrowPrefix = applicationCursor && !shift ? "\u{1b}O" : "\u{1b}[\(shift ? "1;2" : "")"
        return switch action {
        case .escape: Data([0x1b])
        case .tab: Data([0x09])
        case .ctrlModifier: nil
        case .arrowUp: Data("\(arrowPrefix)A".utf8)
        case .arrowDown: Data("\(arrowPrefix)B".utf8)
        case .arrowLeft: Data("\(arrowPrefix)D".utf8)
        case .arrowRight: Data("\(arrowPrefix)C".utf8)
        case .sequence(let value): Data(value.utf8)
        }
    }

    public static func applyCtrl(to character: Character) -> Data? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return Data([ascii & 0x1f])
        default:
            return nil
        }
    }
}
