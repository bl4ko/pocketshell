import CoreText
import Metal
import Testing

@testable import TerminalUI

@Suite(.serialized)
struct GlyphFallbackTests {
    private let device = MTLCreateSystemDefaultDevice()
    private let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)

    private func atlas() throws -> GlyphAtlas {
        let device = try #require(device)
        return try #require(GlyphAtlas(device: device, font: font, scale: 2))
    }

    private func key(_ scalars: [UInt32], span: Int = 1) -> GlyphKey {
        GlyphKey(scalars: scalars, bold: false, italic: false, span: span)
    }

    private func coverage(_ atlas: GlyphAtlas, _ entry: GlyphEntry) -> (rows: Set<Int>, cols: Set<Int>) {
        let pixels = atlas.pixels(of: entry)
        var rows = Set<Int>()
        var cols = Set<Int>()
        for y in 0..<entry.height {
            for x in 0..<entry.width where pixels[(y * entry.width + x) * 4 + 3] > 0 {
                rows.insert(y)
                cols.insert(x)
            }
        }
        return (rows, cols)
    }

    @Test func bundlesTheNerdFontSymbols() throws {
        let symbols = try #require(SymbolFont.make(size: 14))
        #expect(CTFontCopyPostScriptName(symbols) as String == "SymbolsNFM")
        #expect(SymbolFont.glyph(0xF109, in: symbols) != nil)
        #expect(SymbolFont.glyph(0xE0B0, in: symbols) != nil)
        #expect(SymbolFont.glyph(0xF0001, in: symbols) != nil)
    }

    @Test(arguments: [UInt32(0xF109), 0xF108, 0xE0A0, 0xF0001, 0xE5FA])
    func nerdIconsComeFromTheBundledFontCenteredInTheCell(scalar: UInt32) throws {
        let atlas = try atlas()
        #expect(atlas.fontNames(for: key([scalar])) == ["SymbolsNFM"])
        let entry = atlas.entry(for: key([scalar]))
        #expect(!entry.empty)
        #expect(!entry.color)
        #expect(entry.width == atlas.metrics.width)
        let covered = coverage(atlas, entry)
        let top = try #require(covered.rows.min())
        let bottom = try #require(covered.rows.max())
        let left = try #require(covered.cols.min())
        let right = try #require(covered.cols.max())
        #expect(abs(top - (entry.height - 1 - bottom)) <= 2)
        #expect(abs(left - (entry.width - 1 - right)) <= 2)
        #expect(right - left >= entry.width / 2 || bottom - top >= entry.height / 2)
    }

    @Test func powerlineSeparatorsStretchToTheWholeCell() throws {
        let atlas = try atlas()
        #expect(atlas.fontNames(for: key([0xE0B0])) == ["SymbolsNFM"])
        let entry = atlas.entry(for: key([0xE0B0]))
        let covered = coverage(atlas, entry)
        #expect(covered.rows.contains(0))
        #expect(covered.rows.contains(entry.height - 1))
        #expect(covered.cols.contains(0))
        #expect(covered.cols.contains(entry.width - 1))
    }

    @Test func wideNerdIconsUseBothCells() throws {
        let atlas = try atlas()
        let entry = atlas.entry(for: key([0xF109], span: 2))
        #expect(entry.width == atlas.metrics.width * 2)
        let covered = coverage(atlas, entry)
        let left = try #require(covered.cols.min())
        let right = try #require(covered.cols.max())
        #expect(right - left > atlas.metrics.width)
    }

    @Test func primaryFontKeepsTheCharactersItHas() throws {
        let atlas = try atlas()
        #expect(atlas.fontNames(for: key([0x41])) == ["Menlo-Regular"])
    }

    @Test func emojiFallsBackToTheColorFont() throws {
        let atlas = try atlas()
        let names = atlas.fontNames(for: key([0x1F600], span: 2))
        #expect(names.count == 1)
        #expect(names.allSatisfy { $0.contains("AppleColorEmoji") })
        let entry = atlas.entry(for: key([0x1F600], span: 2))
        #expect(entry.color)
        #expect(!coverage(atlas, entry).rows.isEmpty)
    }

    @Test func cjkFallsBackToASystemFontThatHasTheGlyph() throws {
        let atlas = try atlas()
        let names = atlas.fontNames(for: key([0x6F22], span: 2))
        let name = try #require(names.first)
        #expect(names.count == 1)
        #expect(name != "LastResort")
        #expect(name != "Menlo-Regular")
        #expect(name != "SymbolsNFM")
        let entry = atlas.entry(for: key([0x6F22], span: 2))
        #expect(!entry.color)
        #expect(!coverage(atlas, entry).rows.isEmpty)
    }
}
