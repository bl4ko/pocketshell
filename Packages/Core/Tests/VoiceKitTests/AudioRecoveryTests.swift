import Testing
import VoiceKit

@Test func interruptionPausesOnceAndItsEndRestartsTheEngine() {
    var recovery = AudioRecovery()
    #expect(recovery.handle(.interruptionBegan, engineRunning: true) == .pause)
    #expect(recovery.handle(.interruptionBegan, engineRunning: false) == .none)
    #expect(recovery.handle(.interruptionEnded, engineRunning: false) == .restart)
    #expect(recovery.handle(.restarted(true), engineRunning: true) == .resumed)
    #expect(!recovery.paused)
}

@Test func failedRestartStaysPausedUntilTheAppIsActiveAgain() {
    var recovery = AudioRecovery()
    _ = recovery.handle(.interruptionBegan, engineRunning: true)
    #expect(recovery.handle(.interruptionEnded, engineRunning: false) == .restart)
    #expect(recovery.handle(.restarted(false), engineRunning: false) == .none)
    #expect(recovery.paused)
    #expect(recovery.handle(.appActive, engineRunning: false) == .restart)
    #expect(recovery.handle(.restarted(true), engineRunning: true) == .resumed)
}

@Test func interruptionWithoutAnEndResumesWhenTheAppIsActive() {
    var recovery = AudioRecovery()
    _ = recovery.handle(.interruptionBegan, engineRunning: true)
    #expect(recovery.handle(.appActive, engineRunning: false) == .restart)
    #expect(recovery.handle(.restarted(true), engineRunning: true) == .resumed)
}

@Test func activeAppLeavesARunningEngineAlone() {
    var recovery = AudioRecovery()
    #expect(recovery.handle(.appActive, engineRunning: true) == .none)
    #expect(recovery.handle(.interruptionEnded, engineRunning: true) == .none)
}

@Test func stoppedEngineRestartsWithoutAPauseNotice() {
    var recovery = AudioRecovery()
    #expect(recovery.handle(.appActive, engineRunning: false) == .restart)
    #expect(recovery.handle(.restarted(true), engineRunning: true) == .none)
}

@Test func failedRebuildPausesAndTheNextSuccessResumes() {
    var recovery = AudioRecovery()
    #expect(recovery.handle(.restarted(false), engineRunning: false) == .pause)
    #expect(recovery.handle(.restarted(false), engineRunning: false) == .none)
    #expect(recovery.handle(.restarted(true), engineRunning: true) == .resumed)
}
