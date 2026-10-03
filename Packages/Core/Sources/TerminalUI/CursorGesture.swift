import Models

/// A held touch acts as a joystick. Returning to the press point stops key repeat.
enum CursorGesture {
    struct Movement: Equatable {
        let action: ToolbarKey.Action
        let speed: Int

        var interval: Double { [0.18, 0.09, 0.04][speed - 1] }

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

    static func movement(x: Double, y: Double) -> Movement? {
        guard x.isFinite, y.isFinite else { return nil }
        let distance = max(abs(x), abs(y))
        guard distance >= 18 else { return nil }
        let action: ToolbarKey.Action =
            abs(x) > abs(y) ? (x < 0 ? .arrowLeft : .arrowRight) : (y < 0 ? .arrowUp : .arrowDown)
        return Movement(action: action, speed: distance >= 110 ? 3 : distance >= 60 ? 2 : 1)
    }
}
