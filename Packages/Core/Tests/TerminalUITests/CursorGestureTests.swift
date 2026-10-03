import Testing

@testable import TerminalUI

struct CursorGestureTests {
    @Test func restingTouchAndReturnToCenterStopKeys() {
        #expect(CursorGesture.movement(x: 0, y: 0) == nil)
        #expect(CursorGesture.movement(x: 33, y: -33) == nil)
        #expect(CursorGesture.movement(x: .nan, y: 20) == nil)
        #expect(CursorGesture.movement(x: 20, y: .infinity) == nil)
    }

    @Test func dominantAxisChoosesOneArrow() {
        #expect(CursorGesture.movement(x: -50, y: 20)?.action == .arrowLeft)
        #expect(CursorGesture.movement(x: 50, y: -20)?.action == .arrowRight)
        #expect(CursorGesture.movement(x: 20, y: -50)?.action == .arrowUp)
        #expect(CursorGesture.movement(x: -20, y: 50)?.action == .arrowDown)
    }

    @Test func distanceSelectsThreeRepeatSpeeds() {
        let slow = CursorGesture.movement(x: 34, y: 0)
        let medium = CursorGesture.movement(x: 100, y: 0)
        let fast = CursorGesture.movement(x: 180, y: 0)
        #expect(slow?.speed == 1)
        #expect(medium?.speed == 2)
        #expect(fast?.speed == 3)
        #expect(slow!.interval > medium!.interval)
        #expect(medium!.interval > fast!.interval)
    }

    @Test func aShortDragSendsOnlyOneHistoryKeyEvenAtTopSpeed() {
        var gate = CursorGesture.RepeatGate()
        let fast = CursorGesture.movement(x: 0, y: -200)
        #expect(gate.key(for: fast, at: 0) == .arrowUp)
        for time in [0.01, 0.05, 0.1, 0.2, 0.3, 0.4, 0.54] {
            #expect(gate.key(for: fast, at: time) == nil)
        }
        #expect(gate.key(for: nil, at: 0.54) == nil)
        #expect(gate.key(for: nil, at: 1) == nil)
    }

    @Test func heldDragPausesBeforeSlowerRepeat() {
        var gate = CursorGesture.RepeatGate()
        let slow = CursorGesture.movement(x: 0, y: -40)
        #expect(gate.key(for: slow, at: 0) == .arrowUp)
        #expect(gate.key(for: slow, at: 0.54) == nil)
        #expect(gate.key(for: slow, at: 0.55) == .arrowUp)
        #expect(gate.key(for: slow, at: 0.99) == nil)
        #expect(gate.key(for: slow, at: 1) == .arrowUp)
    }

    @Test func fasterMovementKeepsTheInitialPauseAndLimitsRepeat() {
        var gate = CursorGesture.RepeatGate()
        let slow = CursorGesture.movement(x: 0, y: -40)
        let fast = CursorGesture.movement(x: 0, y: -200)
        #expect(gate.key(for: slow, at: 0) == .arrowUp)
        #expect(gate.key(for: fast, at: 0.2) == nil)
        #expect(gate.key(for: fast, at: 0.55) == .arrowUp)
        #expect(gate.key(for: fast, at: 0.7) == nil)
        #expect(gate.key(for: fast, at: 0.74) == .arrowUp)
    }

    @Test func directionAndDeadZoneChangesCannotSendAnImmediateBurst() {
        var gate = CursorGesture.RepeatGate()
        let up = CursorGesture.movement(x: 0, y: -40)
        let right = CursorGesture.movement(x: 40, y: 0)
        #expect(gate.key(for: up, at: 0) == .arrowUp)
        #expect(gate.key(for: right, at: 0.02) == nil)
        #expect(gate.key(for: nil, at: 0.03) == nil)
        #expect(gate.key(for: up, at: 0.04) == nil)
        #expect(gate.key(for: up, at: 0.2) == .arrowUp)
        #expect(gate.key(for: right, at: 0.21) == nil)
        #expect(gate.key(for: right, at: 0.4) == .arrowRight)
    }
}
