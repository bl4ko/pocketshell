import Foundation
import GhosttyVt

public struct VTCellFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold = VTCellFlags(rawValue: 1 << 0)
    public static let italic = VTCellFlags(rawValue: 1 << 1)
    public static let faint = VTCellFlags(rawValue: 1 << 2)
    public static let underline = VTCellFlags(rawValue: 1 << 3)
    public static let doubleUnderline = VTCellFlags(rawValue: 1 << 4)
    public static let curlyUnderline = VTCellFlags(rawValue: 1 << 5)
    public static let strikethrough = VTCellFlags(rawValue: 1 << 6)
    public static let inverse = VTCellFlags(rawValue: 1 << 7)
    public static let invisible = VTCellFlags(rawValue: 1 << 8)
    public static let wide = VTCellFlags(rawValue: 1 << 9)
    public static let spacer = VTCellFlags(rawValue: 1 << 10)
    public static let overline = VTCellFlags(rawValue: 1 << 11)
}

public struct VTCell: Hashable, Sendable {
    public var scalar: UInt32 = 0
    public var extra: [UInt32]?
    public var fg: VTColor?
    public var bg: VTColor?
    public var flags: VTCellFlags = []

    public init() {}

    public var isBlank: Bool { scalar == 0 || scalar == 0x20 }

    public var text: String {
        guard scalar != 0 else { return " " }
        var scalars = String.UnicodeScalarView()
        for value in [scalar] + (extra ?? []) {
            if let unicode = Unicode.Scalar(value) { scalars.append(unicode) }
        }
        return String(scalars)
    }
}

public enum VTCursorStyle: Sendable {
    case block
    case bar
    case underline
    case hollow
}

public struct VTCursorState: Equatable, Sendable {
    public var visible = true
    public var inViewport = false
    public var col = 0
    public var row = 0
    public var wideTail = false
    public var style = VTCursorStyle.block
}

public final class VTScreen {
    public private(set) var cols = 0
    public private(set) var rows = 0
    public private(set) var cells: [VTCell] = []
    public private(set) var selection: [ClosedRange<Int>?] = []
    public private(set) var dirtyRows = IndexSet()
    public private(set) var foreground = VTColor(r: 255, g: 255, b: 255)
    public private(set) var background = VTColor(r: 0, g: 0, b: 0)
    public private(set) var cursorColor: VTColor?
    public private(set) var cursor = VTCursorState()

    public init() {}

    public func cell(col: Int, row: Int) -> VTCell {
        guard row >= 0, row < rows, col >= 0, col < cols else { return VTCell() }
        return cells[row * cols + col]
    }

    public func line(_ row: Int) -> String {
        guard row >= 0, row < rows else { return "" }
        var text = ""
        for col in 0..<cols {
            let cell = cells[row * cols + col]
            if cell.flags.contains(.spacer) { continue }
            text += cell.text
        }
        return text
    }

    func resize(cols: Int, rows: Int) {
        guard cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        cells = Array(repeating: VTCell(), count: cols * rows)
        selection = Array(repeating: nil, count: rows)
    }

    func markAllDirty() {
        dirtyRows = IndexSet(integersIn: 0..<rows)
    }

    func set(row: Int, cells rowCells: [VTCell], selection range: ClosedRange<Int>?) {
        guard row >= 0, row < rows else { return }
        let base = row * cols
        for (index, cell) in rowCells.prefix(cols).enumerated() {
            cells[base + index] = cell
        }
        if rowCells.count < cols {
            for index in rowCells.count..<cols { cells[base + index] = VTCell() }
        }
        selection[row] = range
        dirtyRows.insert(row)
    }

    func set(foreground: VTColor, background: VTColor, cursorColor: VTColor?) {
        if foreground != self.foreground || background != self.background {
            markAllDirty()
        }
        self.foreground = foreground
        self.background = background
        self.cursorColor = cursorColor
    }

    func set(cursor: VTCursorState) {
        self.cursor = cursor
    }

    public func takeDirtyRows() -> IndexSet {
        defer { dirtyRows = IndexSet() }
        return dirtyRows
    }
}

extension VTTerminal {
    @discardableResult
    public func updateScreen() -> Bool {
        guard ghostty_render_state_update(renderStateHandle, handle) == GHOSTTY_SUCCESS else { return false }
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(renderStateHandle, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_get(renderStateHandle, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        var cursorState = GhosttyRenderStateCursor()
        cursorState.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(renderStateHandle, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursorState)
        var stateCols: UInt16 = 0
        var stateRows: UInt16 = 0
        ghostty_render_state_get(renderStateHandle, GHOSTTY_RENDER_STATE_DATA_COLS, &stateCols)
        ghostty_render_state_get(renderStateHandle, GHOSTTY_RENDER_STATE_DATA_ROWS, &stateRows)
        let resized = Int(stateCols) != screen.cols || Int(stateRows) != screen.rows
        screen.resize(cols: Int(stateCols), rows: Int(stateRows))
        screen.set(
            foreground: VTColor(colors.foreground), background: VTColor(colors.background),
            cursorColor: colors.cursor_has_value ? VTColor(colors.cursor) : nil)
        var cursor = VTCursorState()
        cursor.visible = cursorState.visible
        cursor.inViewport = cursorState.viewport_has_value
        if cursorState.viewport_has_value {
            cursor.col = Int(cursorState.viewport_x)
            cursor.row = Int(cursorState.viewport_y)
            cursor.wideTail = cursorState.wide_tail
        }
        switch cursorState.visual_style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: cursor.style = .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: cursor.style = .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: cursor.style = .hollow
        default: cursor.style = .block
        }
        screen.set(cursor: cursor)
        let full = resized || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL
        guard full || dirty == GHOSTTY_RENDER_STATE_DIRTY_PARTIAL else { return false }
        readRows(full: full)
        ghostty_render_state_clean(renderStateHandle)
        return true
    }

    private func readRows(full: Bool) {
        guard
            ghostty_render_state_get(renderStateHandle, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIteratorHandle)
                == GHOSTTY_SUCCESS
        else { return }
        var y = 0
        var rowCells: [VTCell] = []
        rowCells.reserveCapacity(screen.cols)
        var graphemes = [UInt32](repeating: 0, count: 16)
        while ghostty_render_state_row_iterator_next(rowIteratorHandle) {
            defer { y += 1 }
            if !full {
                var rowDirty = false
                ghostty_render_state_row_get(rowIteratorHandle, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
                if !rowDirty { continue }
            }
            var range = GhosttyRenderStateRowSelection()
            range.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
            let selected =
                ghostty_render_state_row_get(rowIteratorHandle, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &range)
                == GHOSTTY_SUCCESS
            guard
                ghostty_render_state_row_get(rowIteratorHandle, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCellsHandle)
                    == GHOSTTY_SUCCESS
            else { continue }
            rowCells.removeAll(keepingCapacity: true)
            while ghostty_render_state_row_cells_next(rowCellsHandle) {
                rowCells.append(readCell(&graphemes))
            }
            screen.set(
                row: y, cells: rowCells, selection: selected ? Int(range.start_x)...Int(range.end_x) : nil)
        }
    }

    private func readCell(_ graphemes: inout [UInt32]) -> VTCell {
        var cell = VTCell()
        var raw: GhosttyCell = 0
        ghostty_render_state_row_cells_get(rowCellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
        var wide = GHOSTTY_CELL_WIDE_NARROW
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
        if wide == GHOSTTY_CELL_WIDE_WIDE {
            cell.flags.insert(.wide)
        } else if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD {
            cell.flags.insert(.spacer)
        }
        var length: UInt32 = 0
        ghostty_render_state_row_cells_get(rowCellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
        if length > 0 {
            if Int(length) > graphemes.count { graphemes = [UInt32](repeating: 0, count: Int(length)) }
            graphemes.withUnsafeMutableBufferPointer {
                _ = ghostty_render_state_row_cells_get(
                    rowCellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, $0.baseAddress)
            }
            cell.scalar = graphemes[0]
            if length > 1 { cell.extra = Array(graphemes[1..<Int(length)]) }
        }
        var color = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(rowCellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &color)
            == GHOSTTY_SUCCESS
        {
            cell.fg = VTColor(color)
        }
        if ghostty_render_state_row_cells_get(rowCellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &color)
            == GHOSTTY_SUCCESS
        {
            cell.bg = VTColor(color)
        }
        var styled = false
        ghostty_render_state_row_cells_get(rowCellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &styled)
        if styled {
            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            ghostty_render_state_row_cells_get(rowCellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
            if style.bold { cell.flags.insert(.bold) }
            if style.italic { cell.flags.insert(.italic) }
            if style.faint { cell.flags.insert(.faint) }
            if style.inverse { cell.flags.insert(.inverse) }
            if style.invisible { cell.flags.insert(.invisible) }
            if style.strikethrough { cell.flags.insert(.strikethrough) }
            if style.overline { cell.flags.insert(.overline) }
            switch style.underline {
            case 0: break
            case 2: cell.flags.insert(.doubleUnderline)
            case 3: cell.flags.insert(.curlyUnderline)
            default: cell.flags.insert(.underline)
            }
        }
        return cell
    }
}
