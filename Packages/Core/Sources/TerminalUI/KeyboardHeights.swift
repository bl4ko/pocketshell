import CoreGraphics
import Foundation

/// The typing keyboard's measured height per screen size, so the shortcut panel replaces it at
/// exactly that height, also on the first swap after a launch or a rotation.
public struct KeyboardHeights: Equatable {
    static let defaultsKey = "pocketshell.keyboardHeights"
    private(set) var heights: [String: Double]

    init(heights: [String: Double] = [:]) {
        self.heights = heights
    }

    init(defaults: UserDefaults) {
        self.init(heights: defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:])
    }

    func save(to defaults: UserDefaults) {
        defaults.set(heights, forKey: Self.defaultsKey)
    }

    static func key(_ screen: CGSize) -> String {
        "\(Int(screen.width.rounded()))x\(Int(screen.height.rounded()))"
    }

    func height(for screen: CGSize) -> CGFloat? {
        heights[Self.key(screen)].map { CGFloat($0) }
    }

    static func estimate(for screen: CGSize) -> CGFloat {
        (screen.height * (screen.height > screen.width ? 0.352 : 0.52)).rounded()
    }

    @discardableResult
    mutating func record(_ height: CGFloat, screen: CGSize) -> Bool {
        let key = Self.key(screen)
        guard heights[key] != Double(height) else { return false }
        heights[key] = Double(height)
        return true
    }
}
