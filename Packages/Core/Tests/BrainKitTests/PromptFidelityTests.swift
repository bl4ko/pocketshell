import Testing

@testable import BrainKit

@Test func anInventedRequestIsNotTheUsersWords() {
    let text =
        "PocketShell should also work with subagents, exposing them to the voice assistant so it can interact with "
        + "and manage them on the user's behalf."
    #expect(!PromptFidelity.isVerbatim(text, turns: ["work in subagents"]))
    #expect(
        !PromptFidelity.isVerbatim(
            "Correction: run the migration tests again.", turns: ["tell claude to run the migration tests again"]))
}

@Test func dictationWithoutFillersAndAddressingIsTheUsersWords() {
    #expect(
        PromptFidelity.isVerbatim(
            "Run the migration tests again.", turns: ["tell claude to um run the uh migration tests again"]))
    #expect(PromptFidelity.isVerbatim("Work in subagents.", turns: ["tell security to work in sub agents"]))
    #expect(PromptFidelity.isVerbatim("Fix the kubectl config.", turns: ["tell codex fix the cube control config"]))
    #expect(
        PromptFidelity.isVerbatim(
            "The login test fails on Safari. Fix it, then run 2 retries.",
            turns: ["what is codex doing", "tell codex the login test fails on safari fix it then run two retries"]))
}

@Test func readBackQuotesTheExactText() {
    #expect(
        PromptFidelity.readBack("Work with subagents", agent: "Claude in api")
            == "I will send to Claude in api: Work with subagents. Send it?")
}
