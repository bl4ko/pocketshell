import Foundation
import Testing

@testable import TerminalUI

@Test func accumulatesUntilStepThenEmitsLine() {
    var tracker = PanScrollTracker(step: 10)
    #expect(tracker.lines(for: 4) == 0)
    #expect(tracker.lines(for: 4) == 0)
    #expect(tracker.lines(for: 4) == 1)
}

@Test func emitsMultipleLinesForBigDelta() {
    var tracker = PanScrollTracker(step: 10)
    #expect(tracker.lines(for: 35) == 3)
    #expect(tracker.lines(for: 5) == 1)
}

@Test func negativeDeltaEmitsNegativeLines() {
    var tracker = PanScrollTracker(step: 10)
    #expect(tracker.lines(for: -25) == -2)
    #expect(tracker.lines(for: -5) == -1)
}

@Test func directionChangeDropsOppositeResidual() {
    var tracker = PanScrollTracker(step: 10)
    #expect(tracker.lines(for: 8) == 0)
    #expect(tracker.lines(for: -8) == 0)
    #expect(tracker.lines(for: -2) == -1)
}

@Test func resetClearsResidual() {
    var tracker = PanScrollTracker(step: 10)
    _ = tracker.lines(for: 9)
    tracker.reset()
    #expect(tracker.lines(for: 9) == 0)
}

@Test func zeroOrNegativeStepClampedToOne() {
    var tracker = PanScrollTracker(step: 0)
    #expect(tracker.lines(for: 3) == 3)
}

@Test func fontZoomScalesAndClamps() {
    #expect(FontZoom.size(base: 13, scale: 1.0) == 13)
    #expect(FontZoom.size(base: 13, scale: 2.0) == 26)
    #expect(FontZoom.size(base: 13, scale: 0.1) == FontZoom.range.lowerBound)
    #expect(FontZoom.size(base: 13, scale: 10) == FontZoom.range.upperBound)
}
