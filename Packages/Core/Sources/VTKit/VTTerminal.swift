import Foundation
import GhosttyVt

public struct VTColor: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ rgb: GhosttyColorRgb) {
        self.init(r: rgb.r, g: rgb.g, b: rgb.b)
    }

    var rgb: GhosttyColorRgb { GhosttyColorRgb(r: r, g: g, b: b) }
}

public struct VTPoint: Hashable, Sendable, Comparable {
    public var col: Int
    public var row: Int

    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }

    public static func < (lhs: VTPoint, rhs: VTPoint) -> Bool {
        lhs.row == rhs.row ? lhs.col < rhs.col : lhs.row < rhs.row
    }
}

public struct VTSelection: Equatable, Sendable {
    public var start: VTPoint
    public var end: VTPoint
    public var rectangle: Bool

    public init(start: VTPoint, end: VTPoint, rectangle: Bool = false) {
        self.start = start
        self.end = end
        self.rectangle = rectangle
    }
}

public enum VTMouseTracking: Sendable {
    case none
    case x10
    case normal
    case button
    case any

    public var reportsPress: Bool { self != .none }
    public var reportsDrag: Bool { self == .button || self == .any }
}

public enum VTMouseButton: Sendable {
    case left
    case middle
    case right
    case wheelUp
    case wheelDown
}

public enum VTMouseAction: Sendable {
    case press
    case release
    case motion
}

public enum VTProgressState: Sendable {
    case remove
    case set
    case error
    case indeterminate
    case pause
}

public struct VTProgress: Equatable, Sendable {
    public var state: VTProgressState
    public var percent: Int?

    public init(state: VTProgressState, percent: Int?) {
        self.state = state
        self.percent = percent
    }
}

public struct VTScrollbar: Equatable, Sendable {
    public var total: Int
    public var offset: Int
    public var length: Int

    public var atBottom: Bool { offset + length >= total }
    public var canScroll: Bool { total > length }
}

public final class VTTerminal {
    public var onWrite: (([UInt8]) -> Void)?
    public var onTitle: ((String) -> Void)?
    public var onClipboard: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onProgress: ((VTProgress) -> Void)?

    public private(set) var cols: Int
    public private(set) var rows: Int
    public private(set) var tracker = CursorAddressTracker()
    public let screen = VTScreen()

    let handle: GhosttyTerminal
    let renderStateHandle: GhosttyRenderState
    var rowIteratorHandle: GhosttyRenderStateRowIterator?
    var rowCellsHandle: GhosttyRenderStateRowCells?
    var keyEncoder: GhosttyKeyEncoder?
    var keyEvent: GhosttyKeyEvent?
    var mouseEncoder: GhosttyMouseEncoder?
    var mouseEvent: GhosttyMouseEvent?
    var cellPixels = (width: UInt32(8), height: UInt32(16))
    private var feeding = false
    private var pendingReplies: [UInt8] = []

    public init(cols: Int, rows: Int, scrollbackLines: Int = 10_000) {
        var terminal: GhosttyTerminal?
        precondition(ghostty_terminal_new(nil, &terminal, UInt16(cols), UInt16(rows)) == GHOSTTY_SUCCESS)
        handle = terminal!
        var state: GhosttyRenderState?
        precondition(ghostty_render_state_new(nil, &state) == GHOSTTY_SUCCESS)
        renderStateHandle = state!
        self.cols = cols
        self.rows = rows
        ghostty_render_state_row_iterator_new(nil, &rowIteratorHandle)
        ghostty_render_state_row_cells_new(nil, &rowCellsHandle)
        ghostty_key_encoder_new(nil, &keyEncoder)
        ghostty_key_event_new(nil, &keyEvent)
        ghostty_mouse_encoder_new(nil, &mouseEncoder)
        ghostty_mouse_event_new(nil, &mouseEvent)
        var lines = scrollbackLines
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        var imageStorage: UInt64 = 0
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &imageStorage)
        installCallbacks()
    }

    deinit {
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_USERDATA, nil)
        ghostty_mouse_event_free(mouseEvent)
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_render_state_row_cells_free(rowCellsHandle)
        ghostty_render_state_row_iterator_free(rowIteratorHandle)
        ghostty_render_state_free(renderStateHandle)
        ghostty_terminal_free(handle)
    }

    private func installCallbacks() {
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        let write: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
            guard let userdata, let data else { return }
            let me = Unmanaged<VTTerminal>.fromOpaque(userdata).takeUnretainedValue()
            me.pendingReplies.append(contentsOf: UnsafeBufferPointer(start: data, count: len))
        }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(write, to: UnsafeRawPointer.self))
        let title: GhosttyTerminalTitleChangedFn = { _, userdata in
            guard let userdata else { return }
            Unmanaged<VTTerminal>.fromOpaque(userdata).takeUnretainedValue().titleChanged()
        }
        ghostty_terminal_set(
            handle, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(title, to: UnsafeRawPointer.self))
        let bell: GhosttyTerminalBellFn = { _, userdata in
            guard let userdata else { return }
            Unmanaged<VTTerminal>.fromOpaque(userdata).takeUnretainedValue().onBell?()
        }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
        let clipboard: GhosttyTerminalClipboardWriteFn = { _, userdata, request in
            guard let userdata, let request else { return }
            let me = Unmanaged<VTTerminal>.fromOpaque(userdata).takeUnretainedValue()
            let write = request.pointee
            var result = GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED
            if write.contents_len > 0, let contents = write.contents {
                let items = UnsafeBufferPointer(start: contents, count: write.contents_len)
                let text = items.first { VTTerminal.string($0.mime).hasPrefix("text/plain") } ?? items[0]
                me.onClipboard?(VTTerminal.string(text.data))
                result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
            }
            var reply = GhosttyClipboardWriteReply(
                size: MemoryLayout<GhosttyClipboardWriteReply>.size, result: result, remember: false)
            write.reply?(request, &reply)
        }
        ghostty_terminal_set(
            handle, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(clipboard, to: UnsafeRawPointer.self))
        let progress: GhosttyTerminalProgressReportFn = { _, userdata, report in
            guard let userdata, let report = report?.pointee else { return }
            let state: VTProgressState =
                switch report.state {
                case GHOSTTY_TERMINAL_PROGRESS_STATE_SET: .set
                case GHOSTTY_TERMINAL_PROGRESS_STATE_ERROR: .error
                case GHOSTTY_TERMINAL_PROGRESS_STATE_INDETERMINATE: .indeterminate
                case GHOSTTY_TERMINAL_PROGRESS_STATE_PAUSE: .pause
                default: .remove
                }
            Unmanaged<VTTerminal>.fromOpaque(userdata).takeUnretainedValue().onProgress?(
                VTProgress(state: state, percent: report.progress < 0 ? nil : Int(report.progress)))
        }
        ghostty_terminal_set(
            handle, GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, unsafeBitCast(progress, to: UnsafeRawPointer.self))
        let size: GhosttyTerminalSizeFn = { _, userdata, out in
            guard let userdata, let out else { return false }
            let me = Unmanaged<VTTerminal>.fromOpaque(userdata).takeUnretainedValue()
            out.pointee = GhosttySizeReportSize(
                rows: UInt16(clamping: me.rows), columns: UInt16(clamping: me.cols), cell_width: me.cellPixels.width,
                cell_height: me.cellPixels.height)
            return true
        }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self))
    }

    static func string(_ value: GhosttyString) -> String {
        guard let ptr = value.ptr, value.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
    }

    private func titleChanged() {
        var value = GhosttyString()
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_TITLE, &value) == GHOSTTY_SUCCESS else { return }
        onTitle?(Self.string(value))
    }

    public func feed(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        tracker.beginChunk()
        tracker.scan(bytes)
        feeding = true
        ghostty_terminal_vt_write(handle, base.assumingMemoryBound(to: UInt8.self), bytes.count)
        feeding = false
        flushReplies()
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { feed($0) }
    }

    public func feed(_ data: Data) {
        data.withUnsafeBytes { feed($0) }
    }

    public func feed(_ text: String) {
        feed(Array(text.utf8))
    }

    private func flushReplies() {
        guard !pendingReplies.isEmpty else { return }
        let replies = pendingReplies
        pendingReplies.removeAll()
        onWrite?(replies)
    }

    public func resize(cols: Int, rows: Int, cellWidth: Int = 8, cellHeight: Int = 16) {
        guard cols > 0, rows > 0 else { return }
        cellPixels = (UInt32(max(1, cellWidth)), UInt32(max(1, cellHeight)))
        ghostty_terminal_resize(handle, UInt16(cols), UInt16(rows), cellPixels.width, cellPixels.height)
        self.cols = cols
        self.rows = rows
        flushReplies()
    }

    public func reset() {
        ghostty_terminal_reset(handle)
    }

    private func read<T>(_ key: GhosttyTerminalData, _ initial: T) -> T? {
        var value = initial
        let result = withUnsafeMutablePointer(to: &value) { ghostty_terminal_get(handle, key, $0) }
        return result == GHOSTTY_SUCCESS ? value : nil
    }

    public func mode(_ value: UInt16, ansi: Bool = false) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, ansi), value: false)
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else {
            return false
        }
        return config.value
    }

    public var cursor: VTPoint {
        VTPoint(
            col: Int(read(GHOSTTY_TERMINAL_DATA_CURSOR_X, UInt16(0)) ?? 0),
            row: Int(read(GHOSTTY_TERMINAL_DATA_CURSOR_Y, UInt16(0)) ?? 0))
    }

    public var cursorVisible: Bool { read(GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, false) ?? true }
    public var cursorAddressed: Bool { tracker.addressed }

    public var isAlternateScreen: Bool {
        read(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, GHOSTTY_TERMINAL_SCREEN_PRIMARY) == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    public var applicationCursor: Bool { mode(1) }
    public var bracketedPaste: Bool { mode(2004) }
    public var focusReporting: Bool { mode(1004) }
    public var synchronizedOutput: Bool { mode(2026) }

    public var mouseTracking: VTMouseTracking {
        guard read(GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, false) == true else { return .none }
        if mode(1003) { return .any }
        if mode(1002) { return .button }
        if mode(1000) { return .normal }
        return .x10
    }

    public var kittyKeyboardFlags: UInt8 { read(GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, UInt8(0)) ?? 0 }

    public var title: String {
        var value = GhosttyString()
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_TITLE, &value) == GHOSTTY_SUCCESS else { return "" }
        return Self.string(value)
    }

    public var scrollbar: VTScrollbar {
        let bar = read(GHOSTTY_TERMINAL_DATA_SCROLLBAR, GhosttyTerminalScrollbar()) ?? GhosttyTerminalScrollbar()
        return VTScrollbar(total: Int(bar.total), offset: Int(bar.offset), length: Int(bar.len))
    }

    public var viewportAtBottom: Bool { read(GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, true) ?? true }

    public func scroll(by delta: Int) {
        guard delta != 0 else { return }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = delta
        ghostty_terminal_scroll_viewport(handle, behavior)
    }

    public func scrollToBottom() {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(handle, behavior)
    }

    public func scroll(toRow row: Int) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_ROW
        behavior.value.row = max(0, row)
        ghostty_terminal_scroll_viewport(handle, behavior)
    }

    public func setColors(foreground: VTColor, background: VTColor, cursor: VTColor?, palette: [VTColor]) {
        var fg = foreground.rgb
        var bg = background.rgb
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        if var color = cursor?.rgb {
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &color)
        } else {
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil)
        }
        guard palette.count == 16 else { return }
        var full = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        let defaults = defaultPalette()
        for index in 0..<256 {
            full[index] = index < 16 ? palette[index].rgb : defaults[index]
        }
        full.withUnsafeBufferPointer { buffer in
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress)
        }
    }

    private func defaultPalette() -> [GhosttyColorRgb] {
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        palette.withUnsafeMutableBufferPointer { buffer in
            _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, buffer.baseAddress)
        }
        return palette
    }
}

extension VTTerminal {
    func point(_ point: VTPoint, tag: GhosttyPointTag) -> GhosttyPoint {
        var value = GhosttyPoint()
        value.tag = tag
        value.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: point.col), y: UInt32(clamping: point.row))
        return value
    }

    func gridRef(_ point: VTPoint, tag: GhosttyPointTag = GHOSTTY_POINT_TAG_SCREEN) -> GhosttyGridRef? {
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(handle, self.point(point, tag: tag), &ref) == GHOSTTY_SUCCESS else {
            return nil
        }
        return ref
    }

    func coordinate(_ ref: GhosttyGridRef, tag: GhosttyPointTag = GHOSTTY_POINT_TAG_SCREEN) -> VTPoint? {
        var ref = ref
        var out = GhosttyPointCoordinate()
        guard ghostty_terminal_point_from_grid_ref(handle, &ref, tag, &out) == GHOSTTY_SUCCESS else { return nil }
        return VTPoint(col: Int(out.x), row: Int(out.y))
    }

    public func screenRow(forViewportRow row: Int) -> Int {
        scrollbar.offset + row
    }

    public func viewportRow(forScreenRow row: Int) -> Int {
        row - scrollbar.offset
    }

    public func lineText(row: Int, tag: VTCoordinateSpace = .active) -> String {
        var scalars = String.UnicodeScalarView()
        forEachCell(row: row, tag: tag) { _, _, cell in scalars.append(contentsOf: cell) }
        return String(scalars)
    }

    public func lineCells(row: Int, tag: VTCoordinateSpace = .active) -> [VTLineCell] {
        var cells: [VTLineCell] = []
        forEachCell(row: row, tag: tag) { col, wide, scalars in
            cells.append(VTLineCell(text: String(scalars), col: col, wide: wide))
        }
        return cells
    }

    private func forEachCell(
        row: Int, tag: VTCoordinateSpace, _ body: (Int, Bool, String.UnicodeScalarView) -> Void
    ) {
        guard var ref = gridRef(VTPoint(col: 0, row: row), tag: tag.ghostty) else { return }
        var buffer = [UInt32](repeating: 0, count: 16)
        for col in 0..<cols {
            ref.x = UInt16(col)
            var cell: GhosttyCell = 0
            guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else { break }
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
            var length = 0
            var result = buffer.withUnsafeMutableBufferPointer {
                ghostty_grid_ref_graphemes(&ref, $0.baseAddress, $0.count, &length)
            }
            if result == GHOSTTY_OUT_OF_SPACE, length > buffer.count {
                buffer = [UInt32](repeating: 0, count: length)
                result = buffer.withUnsafeMutableBufferPointer {
                    ghostty_grid_ref_graphemes(&ref, $0.baseAddress, $0.count, &length)
                }
            }
            var scalars = String.UnicodeScalarView()
            if result == GHOSTTY_SUCCESS, length > 0, buffer[0] != 0 {
                for value in buffer.prefix(length) {
                    if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
                }
            } else {
                scalars.append(" ")
            }
            body(col, wide == GHOSTTY_CELL_WIDE_WIDE, scalars)
        }
    }

    public func lineWrapped(row: Int, tag: VTCoordinateSpace = .active) -> Bool {
        rowFlag(row: row, tag: tag, GHOSTTY_ROW_DATA_WRAP)
    }

    public func hyperlink(at point: VTPoint, tag: VTCoordinateSpace = .active) -> String? {
        guard var ref = gridRef(point, tag: tag.ghostty) else { return nil }
        var length = 0
        guard ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &length) == GHOSTTY_OUT_OF_SPACE, length > 0 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: length)
        guard ghostty_grid_ref_hyperlink_uri(&ref, &bytes, length, &length) == GHOSTTY_SUCCESS else { return nil }
        return String(decoding: bytes.prefix(length), as: UTF8.self)
    }

    public func lineIsContinuation(row: Int, tag: VTCoordinateSpace = .active) -> Bool {
        rowFlag(row: row, tag: tag, GHOSTTY_ROW_DATA_WRAP_CONTINUATION)
    }

    private func rowFlag(row: Int, tag: VTCoordinateSpace, _ key: GhosttyRowData) -> Bool {
        guard var ref = gridRef(VTPoint(col: 0, row: row), tag: tag.ghostty) else { return false }
        var raw: GhosttyRow = 0
        guard ghostty_grid_ref_row(&ref, &raw) == GHOSTTY_SUCCESS else { return false }
        var flag = false
        ghostty_row_get(raw, key, &flag)
        return flag
    }

    public func lines(tag: VTCoordinateSpace = .active, trimRight: Bool = true) -> [String] {
        (0..<rows).map { row in
            let text = lineText(row: row, tag: tag)
            guard trimRight else { return text }
            var scalars = text.unicodeScalars
            while scalars.last == " " { scalars.removeLast() }
            return String(scalars)
        }
    }

    public func visibleText() -> String {
        lines().joined(separator: "\n")
    }
}

public struct VTLineCell: Equatable, Sendable {
    public var text: String
    public var col: Int
    public var wide: Bool
}

public enum VTCoordinateSpace: Sendable {
    case active
    case viewport
    case screen

    var ghostty: GhosttyPointTag {
        switch self {
        case .active: GHOSTTY_POINT_TAG_ACTIVE
        case .viewport: GHOSTTY_POINT_TAG_VIEWPORT
        case .screen: GHOSTTY_POINT_TAG_SCREEN
        }
    }
}
