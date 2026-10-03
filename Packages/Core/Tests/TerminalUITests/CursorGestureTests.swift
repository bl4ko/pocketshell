import Testing

@testable import TerminalUI

struct CursorGestureTests {
    @Test func restingTouchAndReturnToCenterStopKeys() {
        #expect(CursorGesture.movement(x: 0, y: 0) == nil)
        #expect(CursorGesture.movement(x: 17, y: -17) == nil)
        #expect(CursorGesture.movement(x: .nan, y: 20) == nil)
        #expect(CursorGesture.movement(x: 20, y: .infinity) == nil)
    }

    @Test func dominantAxisChoosesOneArrow() {
        #expect(CursorGesture.movement(x: -30, y: 20)?.action == .arrowLeft)
        #expect(CursorGesture.movement(x: 30, y: -20)?.action == .arrowRight)
        #expect(CursorGesture.movement(x: 20, y: -30)?.action == .arrowUp)
        #expect(CursorGesture.movement(x: -20, y: 30)?.action == .arrowDown)
    }

    @Test func distanceSelectsThreeRepeatSpeeds() {
        let slow = CursorGesture.movement(x: 18, y: 0)
        let medium = CursorGesture.movement(x: 60, y: 0)
        let fast = CursorGesture.movement(x: 110, y: 0)
        #expect(slow?.speed == 1)
        #expect(medium?.speed == 2)
        #expect(fast?.speed == 3)
        #expect(slow!.interval > medium!.interval)
        #expect(medium!.interval > fast!.interval)
    }
}
