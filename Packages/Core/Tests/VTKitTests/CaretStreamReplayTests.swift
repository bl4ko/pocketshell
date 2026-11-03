import Foundation
import Testing

@testable import VTKit

struct CaretStreamReplayTests {
    struct Replay {
        var chunks = 0
        var exposures = 0
        var suppressed = 0
        var blips: [String] = []
    }

    static func parse(_ raw: [UInt8]) -> [(Double, [UInt8])] {
        var chunks: [(Double, [UInt8])] = []
        let marker = Array("\n@@".utf8)
        var i = 0
        var current: [UInt8] = []
        var currentTs = 0.0
        while i < raw.count {
            if i + 2 < raw.count, raw[i] == marker[0], raw[i + 1] == marker[1], raw[i + 2] == marker[2] {
                var j = i + 3
                var ts = ""
                while j < raw.count, raw[j] != UInt8(ascii: "@") {
                    ts.append(Character(UnicodeScalar(raw[j])))
                    j += 1
                }
                if !current.isEmpty { chunks.append((currentTs, current)) }
                current = []
                currentTs = Double(ts) ?? 0
                i = j + 2
            } else {
                current.append(raw[i])
                i += 1
            }
        }
        if !current.isEmpty { chunks.append((currentTs, current)) }
        return chunks
    }

    static func replay(_ raw: [UInt8]) -> Replay {
        let terminal = VTTerminal(cols: 200, rows: 50)
        var gate = CaretSettleGate()
        var result = Replay()
        var lastRow = -1
        let feed = parse(raw)
        result.chunks = feed.count
        for (idx, (ts, data)) in feed.enumerated() {
            terminal.feed(data)
            let row = terminal.cursor.row
            let gap = idx + 1 < feed.count ? feed[idx + 1].0 - ts : 10
            guard terminal.cursorVisible else { continue }
            if row != lastRow && lastRow >= 0 {
                result.exposures += 1
                switch gate.evaluate(row: row, addressed: terminal.cursorAddressed, lastFeed: ts, now: ts) {
                case .commit:
                    if !terminal.cursorAddressed && gap < 0.5 {
                        result.blips.append("t=\(ts) row \(lastRow)->\(row) gap=\(Int(gap * 1000))ms")
                    }
                case .wait(let remaining):
                    if gap > remaining && gap < 1.0 {
                        result.blips.append("t=\(ts) timer-commit row \(row) gap=\(Int(gap * 1000))ms")
                    } else {
                        result.suppressed += 1
                    }
                }
            } else {
                _ = gate.evaluate(row: row, addressed: terminal.cursorAddressed, lastFeed: ts, now: ts)
            }
            lastRow = row
        }
        return result
    }

    static func capture() throws -> [UInt8] {
        let url = try #require(
            Bundle.module.url(forResource: "busy-tui-client-stream", withExtension: "raw", subdirectory: "Fixtures"))
        return [UInt8](try Data(contentsOf: url))
    }

    @Test func busyTuiMidFrameParksNeverPaintTheCaret() throws {
        let result = Self.replay(try Self.capture())
        #expect(result.exposures > 50, "capture no longer triggers mid-frame cursor exposure")
        #expect(result.suppressed > 10, "gate no longer exercising the wait path")
        #expect(result.blips == [], "gate committed a mid-frame cursor position")
    }

    @Test func adHocCapture() throws {
        guard let path = ProcessInfo.processInfo.environment["CAPTURE"] else { return }
        let result = Self.replay([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))))
        print("chunks=\(result.chunks) exposures=\(result.exposures) suppressed=\(result.suppressed)")
        #expect(result.blips == [])
    }
}
