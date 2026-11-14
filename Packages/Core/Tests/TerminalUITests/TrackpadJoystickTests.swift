import CoreGraphics
import Testing

@testable import TerminalUI

struct TrackpadJoystickTests {
    private typealias Pad = TrackpadJoystick

    @Test func intervalGrowsFasterWithDistanceAndStopsInTheDeadZone() {
        #expect(Pad.interval(distance: 0) == nil)
        #expect(Pad.interval(distance: Pad.deadZone) == nil)
        #expect(Pad.interval(distance: .infinity) == nil)
        let near = Pad.interval(distance: Pad.deadZone + 1)!
        let middle = Pad.interval(distance: 80)!
        let far = Pad.interval(distance: Pad.fullSpeedDistance)!
        #expect(abs(near - 1 / Pad.slowestRate) < 0.01)
        #expect(near > middle && middle > far)
        #expect(abs(far - 1 / Pad.fastestRate) < 0.0001)
        #expect(Pad.interval(distance: 400) == far)
    }

    @Test func smallMovesSendOneStepEachAndNeverRepeat() {
        var pad = Pad(at: CGPoint(x: 100, y: 100), vertical: false)
        #expect(pad.move(to: CGPoint(x: 104, y: 100), vertical: false, at: 0).isEmpty)
        #expect(pad.move(to: CGPoint(x: 106, y: 100), vertical: false, at: 0.1) == [.right])
        #expect(pad.move(to: CGPoint(x: 100, y: 100), vertical: false, at: 0.2) == [.left])
        #expect(pad.move(to: CGPoint(x: 100, y: 160), vertical: false, at: 0.3).isEmpty)
        #expect(!pad.isHolding)
        #expect(pad.tick(at: 10).isEmpty)
    }

    @Test func holdingFarRepeatsFasterThanHoldingNear() {
        func repeats(at x: CGFloat) -> Int {
            var pad = Pad(at: .zero, vertical: false)
            _ = pad.move(to: CGPoint(x: x, y: 0), vertical: false, at: 0)
            return stride(from: 0.001, through: 1, by: 0.001).reduce(0) { $0 + pad.tick(at: $1).count }
        }
        let near = repeats(at: Pad.deadZone + 2)
        let far = repeats(at: Pad.fullSpeedDistance + 50)
        #expect((7...9).contains(near))
        #expect((45...51).contains(far))
    }

    @Test func holdRepeatsTheDirectionOfTheDisplacement() {
        var pad = Pad(at: CGPoint(x: 200, y: 50), vertical: true)
        #expect(pad.move(to: CGPoint(x: 100, y: 50), vertical: true, at: 0) == [.left])
        #expect(pad.isHolding)
        #expect(pad.tick(at: 0.01).isEmpty)
        #expect(pad.tick(at: 1) == [.left])
        _ = pad.move(to: CGPoint(x: 100, y: 120), vertical: true, at: 1)
        #expect(pad.tick(at: 2) == [.left, .down])
    }

    @Test func retreatingEndsTheHoldAtOnceAndReanchorsAtTheFinger() {
        var pad = Pad(at: .zero, vertical: false)
        _ = pad.move(to: CGPoint(x: 100, y: 0), vertical: false, at: 0)
        #expect(pad.move(to: CGPoint(x: 92, y: 0), vertical: false, at: 0.1).isEmpty)
        #expect(pad.isHolding)
        let slower = pad.horizontal.nextRepeat!
        _ = pad.move(to: CGPoint(x: 120, y: 0), vertical: false, at: 0.1)
        #expect(pad.horizontal.nextRepeat! < slower)
        #expect(pad.move(to: CGPoint(x: 107, y: 0), vertical: false, at: 0.2).isEmpty)
        #expect(!pad.isHolding)
        #expect(pad.horizontal.anchor == 107)
        #expect(pad.tick(at: 5).isEmpty)
        #expect(pad.move(to: CGPoint(x: 101, y: 0), vertical: false, at: 0.3) == [.left])
        #expect(pad.move(to: CGPoint(x: 80, y: 0), vertical: false, at: 0.4) == [.left])
        #expect(pad.horizontal.holding == .left)
    }

    @Test func returningIntoTheDeadZoneStopsWithoutStepsBack() {
        var pad = Pad(at: .zero, vertical: false)
        _ = pad.move(to: CGPoint(x: 25, y: 0), vertical: false, at: 0)
        #expect(pad.isHolding)
        #expect(pad.move(to: CGPoint(x: 18, y: 0), vertical: false, at: 0.1).isEmpty)
        #expect(!pad.isHolding)
        #expect(pad.move(to: CGPoint(x: 15, y: 0), vertical: false, at: 0.2).isEmpty)
    }

    @Test func verticalTracksOnlyWhileAskedAndAnchorsWhereItStarts() {
        var pad = Pad(at: CGPoint(x: 0, y: 0), vertical: false)
        #expect(pad.move(to: CGPoint(x: 0, y: 50), vertical: false, at: 0).isEmpty)
        #expect(pad.move(to: CGPoint(x: 0, y: 51), vertical: true, at: 0).isEmpty)
        #expect(pad.move(to: CGPoint(x: 0, y: 48), vertical: true, at: 0.1) == [.up])
        #expect(!pad.isHolding)
    }
}
