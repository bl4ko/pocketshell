import CoreText
import Metal
import Testing
import VTKit

@testable import TerminalUI

@Suite(.serialized)
struct GhosttyRendererTests {
    private let device = MTLCreateSystemDefaultDevice()
    private let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)

    private func render(_ text: String, cols: Int = 10, rows: Int = 3, caret: CaretPaint? = nil) throws -> (
        pixels: [UInt8], width: Int, metrics: CellMetrics
    ) {
        let device = try #require(device)
        let atlas = try #require(GlyphAtlas(device: device, font: font, scale: 2))
        let palette = RenderPalette(
            background: VTColor(r: 0, g: 0, b: 0), foreground: VTColor(r: 255, g: 255, b: 255),
            cursor: VTColor(r: 0, g: 255, b: 0))
        let renderer = try #require(TerminalRenderer(device: device, atlas: atlas, palette: palette))
        let terminal = VTTerminal(cols: cols, rows: rows)
        terminal.setColors(
            foreground: palette.foreground, background: palette.background, cursor: nil,
            palette: (0..<16).map { VTColor(r: $0 == 1 ? 255 : 0, g: 0, b: 0) })
        terminal.feed(text)
        terminal.updateScreen()
        renderer.update(screen: terminal.screen, dirty: terminal.screen.takeDirtyRows())
        let metrics = atlas.metrics
        let width = metrics.width * cols
        let height = metrics.height * rows
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let instances = renderer.instances(screen: terminal.screen, caret: caret, handles: nil)
        let buffer = try #require(renderer.encode(instances: instances, into: target, background: palette.background))
        buffer.commit()
        buffer.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return (pixels, width, metrics)
    }

    private func cellMax(_ result: (pixels: [UInt8], width: Int, metrics: CellMetrics), col: Int, row: Int) -> (
        b: UInt8, g: UInt8, r: UInt8
    ) {
        var best: (UInt8, UInt8, UInt8) = (0, 0, 0)
        for y in (row * result.metrics.height)..<((row + 1) * result.metrics.height) {
            for x in (col * result.metrics.width)..<((col + 1) * result.metrics.width) {
                let i = (y * result.width + x) * 4
                best = (
                    max(best.0, result.pixels[i]), max(best.1, result.pixels[i + 1]), max(best.2, result.pixels[i + 2])
                )
            }
        }
        return best
    }

    @Test func cellMetricsAreWholeDevicePixels() {
        let metrics = CellMetrics(font: font, scale: 3)
        #expect(metrics.width > 10)
        #expect(metrics.height > metrics.width)
        #expect(metrics.grid(for: CGSize(width: metrics.pointWidth * 80, height: metrics.pointHeight * 24)) == (80, 24))
    }

    @Test func drawsGlyphsOnlyInTheirCells() throws {
        let result = try render("A")
        #expect(cellMax(result, col: 0, row: 0).r > 200)
        #expect(cellMax(result, col: 1, row: 0).r == 0)
        #expect(cellMax(result, col: 0, row: 1).r == 0)
    }

    @Test func paletteColorsReachThePixels() throws {
        let result = try render("\u{1b}[31mX")
        let pixel = cellMax(result, col: 0, row: 0)
        #expect(pixel.r > 200)
        #expect(pixel.g == 0)
    }

    @Test func underlinesUseTheirOwnColor() throws {
        let colored = cellMax(try render("\u{1b}[4;58;2;0;255;0m \u{1b}[59m "), col: 0, row: 0)
        #expect(colored.g == 255)
        #expect(colored.r == 0)
        #expect(cellMax(try render("\u{1b}[4;58;5;1m "), col: 0, row: 0).r == 255)
        #expect(cellMax(try render("\u{1b}[4;58;5;1m "), col: 0, row: 0).g == 0)
        #expect(cellMax(try render("\u{1b}[4m "), col: 0, row: 0).g == 255)
    }

    @Test func blockCaretPaintsCursorColorAndInvertsGlyph() throws {
        let result = try render("A", caret: CaretPaint(col: 1, row: 0, style: .block))
        #expect(cellMax(result, col: 1, row: 0).g == 255)
        #expect(cellMax(result, col: 0, row: 0).g > 200)
    }

    @Test func boxDrawingFillsTheWholeCellHeight() throws {
        let result = try render("│")
        let m = result.metrics
        let column = (0..<m.width).first { x in result.pixels[(0 * result.width + x) * 4 + 2] > 0 }
        let x = try #require(column)
        let top = result.pixels[(0 * result.width + x) * 4 + 2]
        let bottom = result.pixels[((m.height - 1) * result.width + x) * 4 + 2]
        #expect(top == 255)
        #expect(bottom == 255)
    }

    @Test func atlasCachesAndGrows() throws {
        let device = try #require(device)
        let atlas = try #require(GlyphAtlas(device: device, font: font, scale: 3))
        let first = atlas.entry(for: GlyphKey(scalars: [65], bold: false, italic: false, span: 1))
        #expect(atlas.entry(for: GlyphKey(scalars: [65], bold: false, italic: false, span: 1)) == first)
        for scalar in 0x4E00..<0x4E00 + 1200 {
            _ = atlas.entry(for: GlyphKey(scalars: [UInt32(scalar)], bold: false, italic: false, span: 2))
        }
        #expect(atlas.size > 1024)
        #expect(atlas.entry(for: GlyphKey(scalars: [65], bold: false, italic: false, span: 1)) == first)
        #expect(atlas.pixels(of: first).contains { $0 > 0 })
    }

    @Test func spacesAndBlanksProduceNoGlyphInstances() throws {
        let device = try #require(device)
        let atlas = try #require(GlyphAtlas(device: device, font: font, scale: 2))
        let renderer = try #require(
            TerminalRenderer(
                device: device, atlas: atlas,
                palette: RenderPalette(
                    background: VTColor(r: 0, g: 0, b: 0), foreground: VTColor(r: 255, g: 255, b: 255),
                    cursor: VTColor(r: 0, g: 255, b: 0))))
        let terminal = VTTerminal(cols: 20, rows: 2)
        terminal.feed("a b")
        terminal.updateScreen()
        renderer.update(screen: terminal.screen, dirty: terminal.screen.takeDirtyRows())
        #expect(renderer.instances(screen: terminal.screen, caret: nil, handles: nil).count == 2)
    }

    @Test func framesEncodedBeforeCommitKeepTheirOwnInstances() throws {
        let device = try #require(device)
        let atlas = try #require(GlyphAtlas(device: device, font: font, scale: 2))
        let palette = RenderPalette(
            background: VTColor(r: 0, g: 0, b: 0), foreground: VTColor(r: 255, g: 255, b: 255),
            cursor: VTColor(r: 0, g: 255, b: 0))
        let renderer = try #require(TerminalRenderer(device: device, atlas: atlas, palette: palette))
        let terminal = VTTerminal(cols: 10, rows: 1)
        terminal.updateScreen()
        renderer.update(screen: terminal.screen, dirty: terminal.screen.takeDirtyRows())
        let metrics = atlas.metrics
        let width = metrics.width * 10
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: metrics.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        func frame(caretCol: Int) throws -> (MTLTexture, MTLCommandBuffer) {
            let target = try #require(device.makeTexture(descriptor: descriptor))
            let instances = renderer.instances(
                screen: terminal.screen, caret: CaretPaint(col: caretCol, row: 0, style: .block), handles: nil)
            let buffer = try #require(
                renderer.encode(instances: instances, into: target, background: palette.background))
            return (target, buffer)
        }
        let first = try frame(caretCol: 0)
        let second = try frame(caretCol: 5)
        for (_, buffer) in [first, second] { buffer.commit() }
        for (_, buffer) in [first, second] { buffer.waitUntilCompleted() }
        func green(_ target: MTLTexture, col: Int) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            target.getBytes(
                &pixel, bytesPerRow: 4,
                from: MTLRegionMake2D(col * metrics.width + metrics.width / 2, metrics.height / 2, 1, 1), mipmapLevel: 0
            )
            return pixel[1]
        }
        #expect(green(first.0, col: 0) == 255)
        #expect(green(first.0, col: 5) == 0)
        #expect(green(second.0, col: 5) == 255)
    }
}
