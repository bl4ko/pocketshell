import Foundation

enum AutomaticReplyFilter {
    static func shouldSuppress(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.starts(with: [0x1b, 0x5b]), bytes.last == UInt8(ascii: "t"),
            let body = String(bytes: bytes.dropFirst(2).dropLast(), encoding: .utf8)
        else { return false }
        let fields = body.split(separator: ";")
        return ["4", "5", "6", "8", "9"].contains(fields.first.map(String.init))
            && fields.dropFirst().allSatisfy { Int($0) != nil }
    }
}
