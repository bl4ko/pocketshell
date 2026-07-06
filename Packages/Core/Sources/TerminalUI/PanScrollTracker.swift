import Foundation

public struct PanScrollTracker {
    private var residual: Double = 0
    private let step: Double

    public init(step: Double) {
        self.step = max(step, 1)
    }

    public mutating func lines(for delta: Double) -> Int {
        if residual != 0, (residual > 0) != (delta > 0), delta != 0 {
            residual = 0
        }
        residual += delta
        let lines = Int(residual / step)
        residual -= Double(lines) * step
        return lines
    }

    public mutating func reset() {
        residual = 0
    }
}
