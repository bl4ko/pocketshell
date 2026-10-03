import Foundation
import Models
import Testing

@testable import ToolbarUI

@Test func escapeEncodesEsc() {
    #expect(ToolbarKeyEncoder.data(for: .escape) == Data([0x1b]))
}

@Test func tabEncodesTab() {
    #expect(ToolbarKeyEncoder.data(for: .tab) == Data([0x09]))
}

@Test func arrowsEncodeCSISequences() {
    #expect(ToolbarKeyEncoder.data(for: .arrowUp) == Data("\u{1b}[A".utf8))
    #expect(ToolbarKeyEncoder.data(for: .arrowDown) == Data("\u{1b}[B".utf8))
    #expect(ToolbarKeyEncoder.data(for: .arrowRight) == Data("\u{1b}[C".utf8))
    #expect(ToolbarKeyEncoder.data(for: .arrowLeft) == Data("\u{1b}[D".utf8))
}

@Test func shiftedArrowsEncodeModifierSequences() {
    #expect(ToolbarKeyEncoder.data(for: .arrowUp, shift: true) == Data("\u{1b}[1;2A".utf8))
    #expect(ToolbarKeyEncoder.data(for: .arrowDown, shift: true) == Data("\u{1b}[1;2B".utf8))
    #expect(ToolbarKeyEncoder.data(for: .arrowRight, shift: true) == Data("\u{1b}[1;2C".utf8))
    #expect(ToolbarKeyEncoder.data(for: .arrowLeft, shift: true) == Data("\u{1b}[1;2D".utf8))
}

@Test func applicationCursorArrowsUseSS3WithoutChangingShiftEncoding() {
    #expect(ToolbarKeyEncoder.data(for: .arrowUp, applicationCursor: true) == Data("\u{1b}OA".utf8))
    #expect(ToolbarKeyEncoder.data(for: .arrowDown, applicationCursor: true) == Data("\u{1b}OB".utf8))
    #expect(ToolbarKeyEncoder.data(for: .arrowRight, applicationCursor: true) == Data("\u{1b}OC".utf8))
    #expect(ToolbarKeyEncoder.data(for: .arrowLeft, applicationCursor: true) == Data("\u{1b}OD".utf8))
    #expect(
        ToolbarKeyEncoder.data(for: .arrowLeft, shift: true, applicationCursor: true) == Data("\u{1b}[1;2D".utf8))
}

@Test func customSequenceEncodesUTF8() {
    #expect(ToolbarKeyEncoder.data(for: .sequence("\u{02}n")) == Data([0x02, 0x6e]))
}

@Test func ctrlModifierEncodesNothing() {
    #expect(ToolbarKeyEncoder.data(for: .ctrlModifier) == nil)
}

@Test func ctrlAppliedToLowercaseLetter() {
    #expect(ToolbarKeyEncoder.applyCtrl(to: "c") == Data([0x03]))
    #expect(ToolbarKeyEncoder.applyCtrl(to: "b") == Data([0x02]))
    #expect(ToolbarKeyEncoder.applyCtrl(to: "k") == Data([0x0b]))
    #expect(ToolbarKeyEncoder.applyCtrl(to: "l") == Data([0x0c]))
    #expect(ToolbarKeyEncoder.applyCtrl(to: "u") == Data([0x15]))
    #expect(ToolbarKeyEncoder.applyCtrl(to: "z") == Data([0x1a]))
}

@Test func ctrlAppliedToUppercaseLetter() {
    #expect(ToolbarKeyEncoder.applyCtrl(to: "C") == Data([0x03]))
}

@Test func ctrlAppliedToNonLetterPassesThrough() {
    #expect(ToolbarKeyEncoder.applyCtrl(to: "é") == nil)
}
