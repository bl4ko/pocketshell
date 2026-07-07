import Foundation

public struct AppLockGate: Sendable {
    public private(set) var isLocked = false

    private let enabled: Bool
    private let gracePeriod: TimeInterval
    private var backgroundedAt: Date?

    public init(enabled: Bool, gracePeriod: TimeInterval = 0) {
        self.enabled = enabled
        self.gracePeriod = gracePeriod
    }

    public mutating func appLaunched() {
        isLocked = enabled
    }

    public mutating func appBackgrounded(at date: Date) {
        guard enabled else { return }
        backgroundedAt = date
    }

    public mutating func appActivated(at date: Date) {
        guard enabled, let backgroundedAt else { return }
        self.backgroundedAt = nil
        if date.timeIntervalSince(backgroundedAt) >= gracePeriod {
            isLocked = true
        }
    }

    public mutating func unlock() {
        isLocked = false
    }
}
