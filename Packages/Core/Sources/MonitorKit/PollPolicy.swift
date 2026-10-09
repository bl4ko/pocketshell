public struct HostBackoff<Key: Hashable & Sendable>: Sendable {
    public let maxSkips: Int
    private var failures: [Key: Int] = [:]
    private var remaining: [Key: Int] = [:]

    public init(maxSkips: Int = 8) {
        self.maxSkips = maxSkips
    }

    public mutating func shouldAttempt(_ key: Key) -> Bool {
        guard let left = remaining[key], left > 0 else { return true }
        remaining[key] = left - 1
        return false
    }

    public mutating func recordFailure(_ key: Key) {
        let count = min((failures[key] ?? 0) + 1, 32)
        failures[key] = count
        remaining[key] = min(1 << (count - 1), maxSkips)
    }

    public mutating func recordSuccess(_ key: Key) {
        failures[key] = nil
        remaining[key] = nil
    }
}

public enum StatusCarryOver {
    public static func pruned<Value>(
        _ last: [String: Value],
        observed: Set<String>,
        unobservedPrefixes: [String]
    ) -> [String: Value] {
        last.filter { entry in
            observed.contains(entry.key) || unobservedPrefixes.contains { entry.key.hasPrefix($0) }
        }
    }
}
