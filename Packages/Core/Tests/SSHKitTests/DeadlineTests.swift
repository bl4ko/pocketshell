import Foundation
import SSHKit
import Testing

struct DeadlineTests {
    @Test func returnsValueBeforeDeadline() async throws {
        let value = try await withDeadline(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test func throwsWhenOperationIgnoresCancellation() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(seconds: 0.2) {
                await Task.detached { try? await Task.sleep(for: .seconds(2)) }.value
                return 1
            }
        }
        #expect(clock.now - start < .seconds(1.5))
    }

    @Test func lateCompletionAfterDeadlineIsIgnored() async throws {
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(seconds: 0.1) {
                await Task.detached { try? await Task.sleep(for: .milliseconds(400)) }.value
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(700))
    }

    @Test func fastSuccessDoesNotWaitForDeadline() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await withDeadline(seconds: 30) { 7 }
        #expect(value == 7)
        #expect(clock.now - start < .seconds(2))
    }

    @Test func propagatesOperationError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withDeadline(seconds: 5) { throw Boom() }
        }
    }
}
