import Testing

@testable import MonitorKit

struct PollPolicyTests {
    @Test func skipsGrowExponentiallyAndCap() {
        var backoff = HostBackoff<String>(maxSkips: 4)
        let first = backoff.shouldAttempt("a")
        #expect(first)
        var skipCounts: [Int] = []
        for _ in 0..<5 {
            backoff.recordFailure("a")
            var skipped = 0
            while !backoff.shouldAttempt("a") { skipped += 1 }
            skipCounts.append(skipped)
        }
        #expect(skipCounts == [1, 2, 4, 4, 4])
    }

    @Test func successResetsAndHostsAreIndependent() {
        var backoff = HostBackoff<String>()
        backoff.recordFailure("a")
        backoff.recordFailure("a")
        let other = backoff.shouldAttempt("b")
        let blocked = backoff.shouldAttempt("a")
        backoff.recordSuccess("a")
        let afterSuccess = backoff.shouldAttempt("a")
        backoff.recordFailure("a")
        let skipped = backoff.shouldAttempt("a")
        let retried = backoff.shouldAttempt("a")
        #expect(other)
        #expect(!blocked)
        #expect(afterSuccess)
        #expect(!skipped)
        #expect(retried)
    }

    @Test func carryOverKeepsEntriesForUnobservedSessions() {
        let last = ["h:herdr:s1:p1": 1, "h:herdr:s2:p1": 2, "h:herdr:s3:p1": 3, "h:herdr:s1:gone": 4]
        let result = StatusCarryOver.pruned(
            last,
            observed: ["h:herdr:s1:p1"],
            unobservedPrefixes: ["h:herdr:s2:"]
        )
        #expect(result == ["h:herdr:s1:p1": 1, "h:herdr:s2:p1": 2])
    }
}
