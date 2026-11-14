import CoreGraphics

/// The space-bar trackpad: one arrow per small movement near the anchor, and a held arrow whose rate grows
/// with the distance from the anchor. A retreat ends the hold and re-anchors at the finger.
struct TrackpadJoystick {
    static let horizontalStep: CGFloat = 5
    static let verticalStep: CGFloat = 2
    static let deadZone: CGFloat = 20
    static let fullSpeedDistance: CGFloat = 140
    static let slowestRate = 8.0
    static let fastestRate = 50.0
    static let retreat: CGFloat = 12

    enum Key: Equatable { case left, right, up, down }

    struct Axis {
        let step: CGFloat
        let negative: Key
        let positive: Key
        private(set) var anchor: CGFloat
        private var last: CGFloat
        private var peak: CGFloat = 0
        private(set) var holding: Key?
        private var interval = 0.0
        private var lastRepeat = 0.0

        init(at position: CGFloat, step: CGFloat, negative: Key, positive: Key) {
            self.step = step
            self.negative = negative
            self.positive = positive
            anchor = position
            last = position
        }

        var nextRepeat: Double? { holding == nil ? nil : lastRepeat + interval }

        mutating func move(to position: CGFloat, at time: Double) -> Key? {
            let offset = position - anchor
            let distance = abs(offset)
            if let holding {
                guard (offset < 0 ? negative : positive) == holding, distance > deadZone,
                    distance > peak - retreat, let interval = TrackpadJoystick.interval(distance: distance)
                else {
                    release(at: position)
                    return nil
                }
                peak = max(peak, distance)
                self.interval = interval
                return nil
            }
            var key: Key?
            if abs(position - last) > step {
                key = position < last ? negative : positive
                last = position
            }
            if let interval = TrackpadJoystick.interval(distance: distance) {
                holding = offset < 0 ? negative : positive
                peak = distance
                self.interval = interval
                lastRepeat = time
            }
            return key
        }

        mutating func tick(at time: Double) -> Key? {
            guard let next = nextRepeat, time >= next else { return nil }
            lastRepeat = time
            return holding
        }

        private mutating func release(at position: CGFloat) {
            holding = nil
            anchor = position
            last = position
            peak = 0
        }

        private var deadZone: CGFloat { TrackpadJoystick.deadZone }
        private var retreat: CGFloat { TrackpadJoystick.retreat }
    }

    private(set) var horizontal: Axis
    private(set) var vertical: Axis?

    init(at point: CGPoint, vertical: Bool) {
        horizontal = Axis(at: point.x, step: Self.horizontalStep, negative: .left, positive: .right)
        self.vertical = vertical ? Self.verticalAxis(at: point.y) : nil
    }

    var isHolding: Bool { horizontal.holding != nil || vertical?.holding != nil }

    mutating func move(to point: CGPoint, vertical tracksVertical: Bool, at time: Double) -> [Key] {
        var keys: [Key] = []
        if let key = horizontal.move(to: point.x, at: time) { keys.append(key) }
        if !tracksVertical {
            vertical = nil
        } else if vertical == nil {
            vertical = Self.verticalAxis(at: point.y)
        } else if let key = vertical?.move(to: point.y, at: time) {
            keys.append(key)
        }
        return keys
    }

    mutating func tick(at time: Double) -> [Key] {
        [horizontal.tick(at: time), vertical?.tick(at: time)].compactMap { $0 }
    }

    static func interval(distance: CGFloat) -> Double? {
        guard distance.isFinite, distance > deadZone else { return nil }
        let reach = min(1, Double((distance - deadZone) / (fullSpeedDistance - deadZone)))
        return 1 / (slowestRate + (fastestRate - slowestRate) * reach)
    }

    private static func verticalAxis(at position: CGFloat) -> Axis {
        Axis(at: position, step: verticalStep, negative: .up, positive: .down)
    }
}
