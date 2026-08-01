import Testing
import VNCKit

@Test func busyPhasesDriveTheSpinner() {
    #expect(VNCSessionController.Phase.connecting.isBusy)
    #expect(VNCSessionController.Phase.authenticating.isBusy)
    #expect(VNCSessionController.Phase.reconnecting(attempt: 2).isBusy)
    #expect(!VNCSessionController.Phase.connected.isBusy)
    #expect(!VNCSessionController.Phase.failed("boom").isBusy)
}

@Test func overlayLabelsExplainTheWait() {
    #expect(VNCSessionController.Phase.connected.overlayLabel == "waiting for first frame…")
    #expect(VNCSessionController.Phase.reconnecting(attempt: 3).overlayLabel == "reconnecting… (attempt 3)")
    #expect(VNCSessionController.Phase.failed("refused").overlayLabel == "refused")
}
