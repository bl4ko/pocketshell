import Models

/// A held touch acts as a joystick. Returning to the press point stops key repeat.
enum CursorGesture {
    struct Movement: Equatable {
        let action: ToolbarKey.Action
        let speed: Int

        var interval: Double { [0.45, 0.28, 0.18][speed - 1] }

        var symbol: String {
            switch action {
            case .arrowUp: "↑"
            case .arrowDown: "↓"
            case .arrowLeft: "←"
            case .arrowRight: "→"
            default: ""
            }
        }
    }

    /// Send one key on a drag, then pause before repeating. Direction changes and
    /// crossing the dead zone cannot produce a burst of immediate keys.
    struct RepeatGate {
        private var action: ToolbarKey.Action?
        private var nextKeyAt = -Double.infinity
        private var lastKeyAt = -Double.infinity
        private var repeating = false

        mutating func key(for movement: Movement?, at time: Double) -> ToolbarKey.Action? {
            guard let movement else {
                action = nil
                repeating = false
                return nil
            }
            if action != movement.action {
                action = movement.action
                repeating = false
                nextKeyAt = max(time, lastKeyAt + 0.2)
            }
            guard time >= nextKeyAt else { return nil }
            lastKeyAt = time
            nextKeyAt = time + (repeating ? movement.interval : 0.55)
            repeating = true
            return movement.action
        }
    }

    static func movement(x: Double, y: Double) -> Movement? {
        guard x.isFinite, y.isFinite else { return nil }
        let distance = max(abs(x), abs(y))
        guard distance >= 34 else { return nil }
        let action: ToolbarKey.Action =
            abs(x) > abs(y) ? (x < 0 ? .arrowLeft : .arrowRight) : (y < 0 ? .arrowUp : .arrowDown)
        return Movement(action: action, speed: distance >= 180 ? 3 : distance >= 100 ? 2 : 1)
    }
}
