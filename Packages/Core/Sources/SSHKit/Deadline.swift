import Foundation

public struct DeadlineExceeded: Error, CustomStringConvertible {
    public let seconds: Double
    public var description: String { "timed out after \(Int(seconds))s" }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

public func withDeadline<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let once = Once()
    return try await withCheckedThrowingContinuation { continuation in
        let work = Task {
            do {
                let value = try await operation()
                if once.claim() { continuation.resume(returning: value) }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() {
                work.cancel()
                continuation.resume(throwing: DeadlineExceeded(seconds: seconds))
            }
        }
    }
}

extension SSHConnection {
    public func runBounded<T: Sendable>(
        timeout: Double,
        _ body: @escaping @Sendable (SSHConnection) async throws -> T
    ) async throws -> T {
        do {
            let value = try await withDeadline(seconds: timeout) {
                try await self.connect()
                return try await body(self)
            }
            await disconnect()
            return value
        } catch {
            await disconnect()
            throw error
        }
    }
}
