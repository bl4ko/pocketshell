import CoreGraphics
import Foundation
import Testing

@testable import TerminalUI

@Test func keyboardHeightsAreKeptPerScreenSize() {
    var heights = KeyboardHeights()
    let portrait = CGSize(width: 402, height: 874)
    let landscape = CGSize(width: 874, height: 402)
    #expect(heights.height(for: portrait) == nil)
    let first = heights.record(336, screen: portrait)
    let other = heights.record(209, screen: landscape)
    let same = heights.record(336, screen: portrait)
    #expect(first && other && !same)
    #expect(heights.height(for: portrait) == 336)
    #expect(heights.height(for: landscape) == 209)
}

@Test func keyboardHeightsSurviveARelaunch() throws {
    let suite = "keyboard-heights-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var heights = KeyboardHeights(defaults: defaults)
    heights.record(336, screen: CGSize(width: 402, height: 874))
    heights.save(to: defaults)
    #expect(KeyboardHeights(defaults: defaults).height(for: CGSize(width: 402, height: 874)) == 336)
}

@Test func anUnmeasuredScreenGetsAnIPhoneKeyboardEstimate() {
    #expect(KeyboardHeights.estimate(for: CGSize(width: 402, height: 874)) == 308)
    #expect(KeyboardHeights().height(for: CGSize(width: 874, height: 402)) == nil)
}
