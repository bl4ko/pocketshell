import Foundation
import Models

public enum ToolbarKeyEncoder {
    public static func data(for action: ToolbarKey.Action) -> Data? {
        switch action {
        case .escape: Data([0x1b])
        case .tab: Data([0x09])
        case .ctrlModifier: nil
        case .arrowUp: Data("\u{1b}[A".utf8)
        case .arrowDown: Data("\u{1b}[B".utf8)
        case .arrowLeft: Data("\u{1b}[D".utf8)
        case .arrowRight: Data("\u{1b}[C".utf8)
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
