import MonitorKit
import Testing

@Test func findsConsecutiveNumberedOptions() {
    #expect(AgentQuickReply.options(in: "❯ 1. Allow\n  2. Deny\n  3. Explain") == [1, 2, 3])
    #expect(AgentQuickReply.options(in: "1: Bad   2: Fine   3: Good   0: Dismiss") == [1, 2, 3])
}

@Test func rejectsAmbiguousNumbers() {
    #expect(AgentQuickReply.options(in: "build 1.2 failed on 3.4") == [])
    #expect(AgentQuickReply.options(in: "2. Retry\n3. Cancel") == [])
}
