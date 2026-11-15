import Foundation

public enum FontZoom {
    public static let range: ClosedRange<Double> = 8...32
    public static let defaultSize = 14.0

    public enum Step: Sendable {
        case bigger, smaller, reset
    }

    public static func size(base: Double, scale: Double) -> Double {
        min(max(base * scale, range.lowerBound), range.upperBound)
    }

    public static func base(after step: Step, from base: Double) -> Double {
        switch step {
        case .bigger: min(range.upperBound, base.rounded() + 2)
        case .smaller: max(range.lowerBound, base.rounded() - 2)
        case .reset: defaultSize
        }
    }
}
