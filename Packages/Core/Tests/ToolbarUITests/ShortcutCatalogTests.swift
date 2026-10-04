import Models
import Testing

@testable import ToolbarUI

struct ShortcutCatalogTests {
    @Test func arrowPanelOffersEveryDirectionAndNavigationKey() {
        #expect(ShortcutCatalog.categories(multiplexer: false).contains(.arrows))
        #expect(ShortcutCatalog.categories(multiplexer: true).contains(.arrows))
        let chips = ShortcutCatalog.chips(.arrows)
        #expect(
            chips.map(\.action) == [
                .arrowLeft, .arrowDown, .arrowUp, .arrowRight,
                .sequence("\u{1b}[H"), .sequence("\u{1b}[F"), .sequence("\u{1b}[5~"), .sequence("\u{1b}[6~"),
            ])
    }

    @Test func multiplexerChipsCarryThePrefix() {
        let chips = ShortcutCatalog.chips(.multiplexer)
        #expect(chips.first?.action == .sequence("\u{02}c"))
        #expect(chips.contains { $0.action == .sequence("\u{02}d") })
    }

    @Test func windowChipsSelectByNumber() {
        let chips = ShortcutCatalog.windowChips(3)
        #expect(chips.map(\.glyph) == ["0", "1", "2"])
        #expect(chips.last?.action == .sequence("\u{02}2"))
    }

    @Test func favoritesReuseUserKeysWithoutModifiers() {
        let chips = ShortcutCatalog.chips(.favorites, userKeys: ToolbarKey.defaults)
        #expect(!chips.contains { $0.action == .ctrlModifier })
        #expect(!chips.contains { $0.action == .arrowUp })
        #expect(chips.contains { $0.action == .sequence("\u{03}") })
    }

    @Test func multiplexerCategoryOnlyWhenAttached() {
        #expect(!ShortcutCatalog.categories(multiplexer: false).contains(.multiplexer))
        #expect(ShortcutCatalog.categories(multiplexer: true).contains(.multiplexer))
    }

    @Test func herdrCategoryIsAvailableForDirectAndManualAttaches() {
        #expect(ShortcutCatalog.categories(multiplexer: false).contains(.herdr))
        #expect(ShortcutCatalog.categories(multiplexer: true).contains(.herdr))
    }

    @Test func herdrChipsUseHerdrDefaultBindings() {
        let chips = ShortcutCatalog.chips(.herdr)
        let expected: [(String, String)] = [
            ("spaces", "w"), ("go to", "g"), ("sidebar", "b"), ("help", "?"),
            ("new tab", "c"), ("prev tab", "p"), ("next tab", "n"), ("rename tab", "T"),
            ("pane left", "h"), ("pane down", "j"), ("pane up", "k"), ("pane right", "l"),
            ("split vertical", "v"), ("split horizontal", "-"), ("zoom", "z"), ("resize", "r"),
            ("new space", "N"), ("rename space", "W"), ("new worktree", "G"), ("notification", "o"),
            ("scrollback", "e"), ("settings", "s"), ("reload config", "R"), ("detach", "q"),
            ("close pane", "x"), ("close tab", "X"), ("close space", "D"),
        ]
        for (label, key) in expected {
            #expect(chips.first { $0.label == label }?.action == .sequence("\u{02}" + key))
        }
        #expect(Set(chips.map(\.id)).count == chips.count)
    }

    @Test func herdrTabsStartAtOneAndRespectThePrefix() {
        let chips = ShortcutCatalog.chips(.herdr, prefix: "\u{01}")
        let tabs = chips.filter { $0.label.hasPrefix("tab ") }
        #expect(tabs.map(\.glyph) == (1...9).map(String.init))
        #expect(tabs.map(\.action) == (1...9).map { .sequence("\u{01}\($0)") })
        #expect(!chips.contains { $0.action == .sequence("\u{01}0") })
    }
}
