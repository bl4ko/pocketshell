import CoreGraphics

/// Maps a point in the terminal scroll view's own coordinates to a visible cell.
/// The view is a scroll view, so its points include `contentOffset`.
public enum TerminalCell {
    public static func at(
        _ point: CGPoint, contentOffset: CGPoint, viewport: CGSize, rows: Int, cols: Int
    ) -> (row: Int, col: Int) {
        guard viewport.width > 0, viewport.height > 0 else { return (0, 0) }
        let row = Int((point.y - contentOffset.y) / viewport.height * CGFloat(rows))
        let col = Int((point.x - contentOffset.x) / viewport.width * CGFloat(cols))
        return (min(max(row, 0), max(rows - 1, 0)), min(max(col, 0), max(cols - 1, 0)))
    }
}
