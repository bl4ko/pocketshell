import RoyalVNCKit
import Testing

@testable import VNCKit

@Test func parsesCommandLetter() {
    let combo = VNCKeyCombo.parse("cmd+h")
    #expect(combo?.modifiers == [VNCKeyCode.commandForARD])
    #expect(combo?.key == VNCKeyCode(asciiCharacter: UInt8(ascii: "h")))
    #expect(combo?.label == "⌘H")
}

@Test func parsesCommandSpace() {
    let combo = VNCKeyCombo.parse("cmd+space")
    #expect(combo?.modifiers == [VNCKeyCode.commandForARD])
    #expect(combo?.key == VNCKeyCode.space)
    #expect(combo?.label == "⌘Space")
}

@Test func parsesMultipleModifiers() {
    let combo = VNCKeyCombo.parse("cmd+shift+4")
    #expect(combo?.modifiers == [VNCKeyCode.commandForARD, VNCKeyCode.shift])
    #expect(combo?.key == VNCKeyCode(asciiCharacter: UInt8(ascii: "4")))
    #expect(combo?.label == "⌘⇧4")
}

@Test func parsesControlAltNamedKey() {
    let combo = VNCKeyCombo.parse("ctrl+alt+delete")
    #expect(combo?.modifiers == [VNCKeyCode.control, VNCKeyCode.optionForARD])
    #expect(combo?.key == VNCKeyCode.forwardDelete)
}

@Test func parseIsCaseAndSpaceInsensitive() {
    let combo = VNCKeyCombo.parse(" CMD + Tab ")
    #expect(combo?.modifiers == [VNCKeyCode.commandForARD])
    #expect(combo?.key == VNCKeyCode.tab)
    #expect(combo?.label == "⌘Tab")
}

@Test func parsesFunctionKey() {
    let combo = VNCKeyCombo.parse("cmd+f5")
    #expect(combo?.key == VNCKeyCode.f5)
}

@Test func parseRejectsUnknownKey() {
    #expect(VNCKeyCombo.parse("cmd+bogus") == nil)
}

@Test func parseRejectsModifierOnly() {
    #expect(VNCKeyCombo.parse("cmd") == nil)
    #expect(VNCKeyCombo.parse("cmd+shift") == nil)
}

@Test func parseRejectsEmpty() {
    #expect(VNCKeyCombo.parse("") == nil)
    #expect(VNCKeyCombo.parse(" + ") == nil)
}

@Test func plainKeyWithoutModifiersParses() {
    let combo = VNCKeyCombo.parse("escape")
    #expect(combo?.modifiers.isEmpty == true)
    #expect(combo?.key == VNCKeyCode.escape)
    #expect(combo?.label == "Esc")
}

@Test func presetsAllParse() {
    for preset in VNCKeyCombo.presets {
        #expect(!preset.label.isEmpty)
    }
    #expect(VNCKeyCombo.presets.count >= 8)
}

@Test func presetsIncludeDesktopSwitchingAndFullscreenExit() {
    let labels = VNCKeyCombo.presets.map(\.label)
    #expect(labels.contains("⌃←"))
    #expect(labels.contains("⌃→"))
    #expect(labels.contains("⌃↑"))
    #expect(labels.contains("⌃⌘F"))
}

@Test func parsesControlCommandCombo() {
    let combo = VNCKeyCombo.parse("ctrl+cmd+f")
    #expect(combo?.modifiers == [VNCKeyCode.control, VNCKeyCode.commandForARD])
    #expect(combo?.key == VNCKeyCode(asciiCharacter: UInt8(ascii: "f")))
    #expect(combo?.label == "⌃⌘F")
}
