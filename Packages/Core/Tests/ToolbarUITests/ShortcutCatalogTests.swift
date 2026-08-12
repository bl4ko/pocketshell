import Models
import Testing

@testable import ToolbarUI

struct ShortcutCatalogTests {
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
}
