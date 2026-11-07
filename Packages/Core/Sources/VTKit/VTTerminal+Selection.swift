import Foundation
import GhosttyVt

extension VTTerminal {
    private func emptySelection() -> GhosttySelection {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        return selection
    }

    private func convert(_ raw: GhosttySelection) -> VTSelection? {
        var raw = raw
        var ordered = emptySelection()
        if ghostty_terminal_selection_ordered(handle, &raw, GHOSTTY_SELECTION_ORDER_FORWARD, &ordered)
            != GHOSTTY_SUCCESS
        {
            ordered = raw
        }
        guard let start = coordinate(ordered.start), let end = coordinate(ordered.end) else { return nil }
        return VTSelection(start: start, end: end, rectangle: ordered.rectangle)
    }

    public var selection: VTSelection? {
        var raw = emptySelection()
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SELECTION, &raw) == GHOSTTY_SUCCESS else {
            return nil
        }
        return convert(raw)
    }

    public var hasSelection: Bool {
        var raw = emptySelection()
        return ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SELECTION, &raw) == GHOSTTY_SUCCESS
    }

    public func select(_ selection: VTSelection?) {
        guard let selection else {
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
            return
        }
        guard let start = gridRef(clamped(selection.start)), let end = gridRef(clamped(selection.end)) else { return }
        var raw = emptySelection()
        raw.start = start
        raw.end = end
        raw.rectangle = selection.rectangle
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, &raw)
    }

    public func clearSelection() {
        select(nil)
    }

    private func clamped(_ point: VTPoint) -> VTPoint {
        let total = max(1, scrollbar.total)
        return VTPoint(col: min(max(0, point.col), cols - 1), row: min(max(0, point.row), total - 1))
    }

    @discardableResult
    public func selectWord(at point: VTPoint) -> VTSelection? {
        guard let ref = gridRef(clamped(point)) else { return nil }
        var options = GhosttyTerminalSelectWordOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
        options.ref = ref
        var raw = emptySelection()
        guard ghostty_terminal_select_word(handle, &options, &raw) == GHOSTTY_SUCCESS else { return nil }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, &raw)
        return selection
    }

    @discardableResult
    public func selectLine(at point: VTPoint) -> VTSelection? {
        guard let ref = gridRef(clamped(point)) else { return nil }
        var options = GhosttyTerminalSelectLineOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.size
        options.ref = ref
        var raw = emptySelection()
        guard ghostty_terminal_select_line(handle, &options, &raw) == GHOSTTY_SUCCESS else { return nil }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, &raw)
        return selection
    }

    @discardableResult
    public func selectAll() -> VTSelection? {
        var raw = emptySelection()
        guard ghostty_terminal_select_all(handle, &raw) == GHOSTTY_SUCCESS else { return nil }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, &raw)
        return selection
    }

    public func selectionText() -> String? {
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = true
        options.trim = true
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_terminal_selection_format_alloc(handle, nil, options, &pointer, &length) == GHOSTTY_SUCCESS,
            let pointer
        else { return nil }
        defer { ghostty_free(nil, pointer, length) }
        let text = String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
        return text.replacingOccurrences(of: "\u{0}", with: " ")
    }
}
