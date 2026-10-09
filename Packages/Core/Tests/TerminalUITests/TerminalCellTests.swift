import CoreGraphics
import Testing

@testable import TerminalUI

@Test func cellIgnoresScrollbackOffset() {
    let cell = TerminalCell.at(
        CGPoint(x: 15, y: 5000 + 25), contentOffset: CGPoint(x: 0, y: 5000),
        viewport: CGSize(width: 100, height: 100), rows: 10, cols: 10)
    #expect(cell.row == 2)
    #expect(cell.col == 1)
}

@Test func cellClampsToViewport() {
    let size = CGSize(width: 100, height: 100)
    let low = TerminalCell.at(CGPoint(x: -5, y: -5), contentOffset: .zero, viewport: size, rows: 10, cols: 10)
    let high = TerminalCell.at(CGPoint(x: 500, y: 500), contentOffset: .zero, viewport: size, rows: 10, cols: 10)
    #expect(low.row == 0 && low.col == 0)
    #expect(high.row == 9 && high.col == 9)
}
