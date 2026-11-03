import CoreGraphics
import VTKit

enum SelectionHandleSide: Equatable {
    case start
    case end
}

enum HandleGrabMath {
    struct Grab: Equatable {
        var handle: SelectionHandleSide
        var colOffset: Int
        var rowOffset: Int
    }

    static func grab(
        point: CGPoint, start: (col: Int, row: Int), end: (col: Int, row: Int), cellWidth: CGFloat,
        cellHeight: CGFloat, slop: CGFloat
    ) -> Grab? {
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let startAnchor = CGPoint(x: CGFloat(start.col) * cellWidth, y: CGFloat(start.row) * cellHeight)
        let endAnchor = CGPoint(x: CGFloat(end.col + 1) * cellWidth, y: CGFloat(end.row + 1) * cellHeight)
        let startDistance = hypot(point.x - startAnchor.x, point.y - startAnchor.y)
        let endDistance = hypot(point.x - endAnchor.x, point.y - endAnchor.y)
        guard min(startDistance, endDistance) <= slop else { return nil }
        let hitCol = Int((point.x / cellWidth).rounded(.down))
        let hitRow = Int((point.y / cellHeight).rounded(.down))
        if startDistance <= endDistance {
            return Grab(handle: .start, colOffset: start.col - hitCol, rowOffset: start.row - hitRow)
        }
        return Grab(handle: .end, colOffset: end.col - hitCol, rowOffset: end.row - hitRow)
    }
}

enum SplitPanes {
    static func hasVerticalDivider(_ screen: VTScreen) -> Bool {
        guard screen.rows >= 3, screen.cols >= 3 else { return false }
        let threshold = max(3, screen.rows / 2)
        let dividers: Set<UInt32> = [0x2502, 0x2503, 0x2551]
        for col in 1..<(screen.cols - 1) {
            var matches = 0
            for row in 0..<screen.rows where dividers.contains(screen.cell(col: col, row: row).scalar) {
                matches += 1
            }
            if matches >= threshold { return true }
        }
        return false
    }
}
