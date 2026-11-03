import CoreGraphics
import CoreText
import Foundation

public struct CellMetrics: Equatable, Sendable {
    public let pointSize: CGFloat
    public let scale: CGFloat
    public let width: Int
    public let height: Int
    public let baseline: Int
    public let underlinePosition: Int
    public let underlineThickness: Int

    public var pointWidth: CGFloat { CGFloat(width) / scale }
    public var pointHeight: CGFloat { CGFloat(height) / scale }

    public init(font: CTFont, scale: CGFloat) {
        let scaled = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * scale, nil, nil)
        var glyph = CGGlyph(0)
        var character = UniChar(("M" as Unicode.Scalar).value)
        CTFontGetGlyphsForCharacters(scaled, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(scaled, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(scaled)
        let descent = CTFontGetDescent(scaled)
        let leading = CTFontGetLeading(scaled)
        pointSize = CTFontGetSize(font)
        self.scale = scale
        width = max(1, Int(advance.width.rounded()))
        height = max(1, Int((ascent + descent + leading).rounded(.up)))
        baseline = max(1, Int((descent + leading / 2).rounded()))
        underlineThickness = max(1, Int(CTFontGetUnderlineThickness(scaled).rounded()))
        underlinePosition = max(0, baseline + Int(CTFontGetUnderlinePosition(scaled).rounded()) - underlineThickness)
    }

    public func grid(for size: CGSize) -> (cols: Int, rows: Int) {
        let cols = Int((size.width * scale) / CGFloat(width))
        let rows = Int((size.height * scale) / CGFloat(height))
        return (max(1, cols), max(1, rows))
    }
}
