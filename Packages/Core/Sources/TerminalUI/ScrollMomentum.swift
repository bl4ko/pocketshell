import Foundation

public struct ScrollMomentum {
    private static let decayPerMillisecond = 0.998
    private static let stopSpeed = 20.0
    private var velocity: Double

    public init(velocity: Double) {
        self.velocity = velocity
    }

    public var isActive: Bool { abs(velocity) >= Self.stopSpeed }

    public mutating func advance(by seconds: Double) -> Double {
        guard isActive, seconds > 0 else { return 0 }
        let travelled = velocity * seconds
        velocity *= pow(Self.decayPerMillisecond, seconds * 1000)
        return travelled
    }
}
