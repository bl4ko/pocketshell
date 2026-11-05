import CoreGraphics
import CoreText
import Foundation

enum SymbolFont {
    static let url = Bundle.module.url(
        forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf", subdirectory: "Fonts")

    static func make(size: CGFloat) -> CTFont? {
        guard let url,
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let descriptor = descriptors.first
        else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    static func isPrivateUse(_ scalar: UInt32) -> Bool {
        (0xE000...0xF8FF).contains(scalar) || (0xF0000...0xFFFFD).contains(scalar)
            || (0x100000...0x10FFFD).contains(scalar)
    }

    static func stretches(_ scalar: UInt32) -> Bool {
        (0xE0B0...0xE0D7).contains(scalar)
    }

    static func glyph(_ scalar: UInt32, in font: CTFont) -> CGGlyph? {
        guard let value = Unicode.Scalar(scalar) else { return nil }
        var units = Array(String(Character(value)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count), glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }

    static func draw(_ glyph: CGGlyph, font: CTFont, stretch: Bool, in context: CGContext, width: Int, height: Int) {
        var glyph = glyph
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        guard bounds.width > 0, bounds.height > 0 else { return }
        var sx = CGFloat(width) / bounds.width
        var sy = CGFloat(height) / bounds.height
        if !stretch {
            sx = min(sx, sy)
            sy = sx
        }
        context.translateBy(
            x: (CGFloat(width) - bounds.width * sx) / 2 - bounds.minX * sx,
            y: (CGFloat(height) - bounds.height * sy) / 2 - bounds.minY * sy)
        context.scaleBy(x: sx, y: sy)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        var origin = CGPoint.zero
        CTFontDrawGlyphs(font, &glyph, &origin, 1, context)
    }
}
