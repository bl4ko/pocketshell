import CoreGraphics
import CoreText
import Foundation
import Metal

struct GlyphKey: Hashable {
    var scalars: [UInt32]
    var bold: Bool
    var italic: Bool
    var span: Int
}

struct GlyphEntry: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var color: Bool
    var empty: Bool
}

final class GlyphAtlas {
    let device: MTLDevice
    let metrics: CellMetrics
    private(set) var texture: MTLTexture
    private(set) var size: Int
    private(set) var generation = 0
    private var entries: [GlyphKey: GlyphEntry] = [:]
    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0
    private let fonts: [CTFont]
    private let symbols: CTFont?
    private let maxSize = 4096

    init?(device: MTLDevice, font: CTFont, scale: CGFloat) {
        self.device = device
        metrics = CellMetrics(font: font, scale: scale)
        let base = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * scale, nil, nil)
        func variant(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
        }
        fonts = [base, variant(.traitBold), variant(.traitItalic), variant([.traitBold, .traitItalic])]
        symbols = SymbolFont.make(size: CTFontGetSize(base))
        size = 1024
        guard let texture = Self.makeTexture(device: device, size: size) else { return nil }
        self.texture = texture
    }

    var count: Int { entries.count }

    private static func makeTexture(device: MTLDevice, size: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    func entry(for key: GlyphKey) -> GlyphEntry {
        if let entry = entries[key] { return entry }
        let entry = rasterize(key)
        entries[key] = entry
        return entry
    }

    private func reserve(width: Int, height: Int) -> (Int, Int)? {
        if shelfX + width > size {
            shelfY += shelfHeight
            shelfX = 0
            shelfHeight = 0
        }
        if shelfY + height > size {
            guard grow() else { return nil }
            return reserve(width: width, height: height)
        }
        defer {
            shelfX += width
            shelfHeight = max(shelfHeight, height)
        }
        return (shelfX, shelfY)
    }

    private func grow() -> Bool {
        let next = size * 2
        guard next <= maxSize, let bigger = Self.makeTexture(device: device, size: next) else {
            generation += 1
            entries.removeAll()
            shelfX = 0
            shelfY = 0
            shelfHeight = 0
            return true
        }
        let bytesPerRow = size * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * size)
        texture.getBytes(
            &bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        bigger.replace(
            region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytesPerRow)
        shelfY = size
        shelfX = 0
        shelfHeight = 0
        texture = bigger
        size = next
        return true
    }

    private func rasterize(_ key: GlyphKey) -> GlyphEntry {
        let width = metrics.width * max(1, key.span)
        let height = metrics.height
        let blank = GlyphEntry(x: 0, y: 0, width: 0, height: 0, color: false, empty: true)
        guard let first = key.scalars.first, first != 0, first != 0x20 || key.scalars.count > 1 else { return blank }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        var color = false
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setShouldAntialias(true)
            if key.scalars.count == 1, BoxDrawing.handles(first) {
                context.setShouldAntialias(BoxDrawing.rounded(first) != nil)
                return BoxDrawing.draw(
                    first, in: context, width: width, height: height, thickness: metrics.underlineThickness)
            }
            if let symbols, let glyph = symbolGlyph(for: key) {
                SymbolFont.draw(
                    glyph, font: symbols, stretch: SymbolFont.stretches(first), in: context, width: width,
                    height: height)
                return true
            }
            let line = self.line(for: key)
            for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                if let runFont = attributes[kCTFontAttributeName as String],
                    CTFontGetSymbolicTraits(runFont as! CTFont).contains(.traitColorGlyphs)
                {
                    color = true
                }
            }
            var x: CGFloat = 0
            if color {
                let bounds = CTLineGetImageBounds(line, context)
                if bounds.width > CGFloat(width) || bounds.height > CGFloat(height) {
                    let ratio = min(CGFloat(width) / max(bounds.width, 1), CGFloat(height) / max(bounds.height, 1))
                    context.translateBy(x: 0, y: CGFloat(height) * (1 - ratio) / 2)
                    context.scaleBy(x: ratio, y: ratio)
                }
            } else {
                let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                if lineWidth > 0, lineWidth < CGFloat(width) - 1, key.span > 1 {
                    x = ((CGFloat(width) - lineWidth) / 2).rounded()
                }
            }
            context.textPosition = CGPoint(x: x, y: CGFloat(metrics.baseline))
            CTLineDraw(line, context)
            return true
        }
        guard drawn, let origin = reserve(width: width, height: height) else { return blank }
        texture.replace(
            region: MTLRegionMake2D(origin.0, origin.1, width, height), mipmapLevel: 0, withBytes: pixels,
            bytesPerRow: bytesPerRow)
        return GlyphEntry(x: origin.0, y: origin.1, width: width, height: height, color: color, empty: false)
    }

    private func font(for key: GlyphKey) -> CTFont {
        fonts[(key.bold ? 1 : 0) + (key.italic ? 2 : 0)]
    }

    private func string(for key: GlyphKey) -> String {
        var scalars = String.UnicodeScalarView()
        for value in key.scalars {
            if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
        }
        return String(scalars)
    }

    private func line(for key: GlyphKey) -> CTLine {
        let attributed = NSAttributedString(
            string: string(for: key),
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font(for: key),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ])
        return CTLineCreateWithAttributedString(attributed)
    }

    private func symbolGlyph(for key: GlyphKey) -> CGGlyph? {
        guard let symbols, let first = key.scalars.first,
            key.scalars.dropFirst().allSatisfy({ $0 == 0xFE0E || $0 == 0xFE0F }),
            let glyph = SymbolFont.glyph(first, in: symbols)
        else { return nil }
        let primary = font(for: key)
        if SymbolFont.glyph(first, in: primary) != nil { return nil }
        if SymbolFont.isPrivateUse(first) { return glyph }
        let text = string(for: key) as CFString
        let fallback = CTFontCreateForString(primary, text, CFRange(location: 0, length: CFStringGetLength(text)))
        return CTFontCopyPostScriptName(fallback) as String == "LastResort" ? glyph : nil
    }

    func fontNames(for key: GlyphKey) -> [String] {
        if let symbols, symbolGlyph(for: key) != nil { return [CTFontCopyPostScriptName(symbols) as String] }
        return ((CTLineGetGlyphRuns(line(for: key)) as? [CTRun]) ?? []).compactMap { run in
            guard let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] else {
                return nil
            }
            return CTFontCopyPostScriptName(font as! CTFont) as String
        }
    }

    func pixels(of entry: GlyphEntry) -> [UInt8] {
        guard !entry.empty else { return [] }
        let bytesPerRow = entry.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * entry.height)
        texture.getBytes(
            &bytes, bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(entry.x, entry.y, entry.width, entry.height), mipmapLevel: 0)
        return bytes
    }
}
