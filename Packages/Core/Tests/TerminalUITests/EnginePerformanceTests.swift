import CoreText
import Foundation
import Metal
import Testing
import VTKit

@testable import TerminalUI

struct EnginePerformanceTests {
    private static func stream(megabytes: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var line = 0
        while bytes.count < megabytes * 1_000_000 {
            line += 1
            bytes += Array(
                "\u{1b}[3\(line % 8)m\(line)\u{1b}[0m │ build step \(line) compiling module_\(line % 97).swift ⠋ 漢字 ok\r\n"
                    .utf8)
        }
        return bytes
    }

    private static func time(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    @Test func measureParseAndFrameCost() throws {
        guard ProcessInfo.processInfo.environment["PS_PERF"] == "1" else { return }
        let data = Self.stream(megabytes: 11)
        let chunks = stride(from: 0, to: data.count, by: 16_384).map { Array(data[$0..<min($0 + 16_384, data.count)]) }
        let ghostty = VTTerminal(cols: 120, rows: 40)
        let ghosttyMs = Self.time { for chunk in chunks { ghostty.feed(chunk) } }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = try #require(
            GlyphAtlas(device: device, font: CTFontCreateWithName("Menlo" as CFString, 14, nil), scale: 3))
        let renderer = try #require(
            TerminalRenderer(
                device: device, atlas: atlas,
                palette: RenderPalette(
                    background: VTColor(r: 0, g: 0, b: 0), foreground: VTColor(r: 255, g: 255, b: 255),
                    cursor: VTColor(r: 200, g: 200, b: 200))))
        var frames: [Double] = []
        for chunk in chunks.prefix(200) {
            ghostty.feed(chunk)
            frames.append(
                Self.time {
                    ghostty.updateScreen()
                    renderer.update(screen: ghostty.screen, dirty: ghostty.screen.takeDirtyRows())
                    _ = renderer.instances(screen: ghostty.screen, caret: nil, handles: nil)
                })
        }
        frames.sort()
        print(
            "PERF bytes=\(data.count) ghostty_feed_ms=\(Int(ghosttyMs)) "
                + "frame_build_p50_ms=\(String(format: "%.2f", frames[frames.count / 2])) "
                + "frame_build_p95_ms=\(String(format: "%.2f", frames[frames.count * 95 / 100]))")
        #expect(ghosttyMs > 0)
    }
}
