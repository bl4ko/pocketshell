import Foundation

public enum FontZoom {
    public static let range: ClosedRange<Double> = 8...32

    public static func size(base: Double, scale: Double) -> Double {
        min(max(base * scale, range.lowerBound), range.upperBound)
    }
}
