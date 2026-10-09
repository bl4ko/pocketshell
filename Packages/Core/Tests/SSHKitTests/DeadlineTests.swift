import SSHKit
import Testing

struct DeadlineTests {
    @Test func returnsValueBeforeDeadline() async throws {
        let value = try await withDeadline(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test func throwsWhenOperationNeverFinishes() async {
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(seconds: 0.2) {
                await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }
            }
        }
    }

    @Test func propagatesOperationError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withDeadline(seconds: 5) { throw Boom() }
        }
    }
}
