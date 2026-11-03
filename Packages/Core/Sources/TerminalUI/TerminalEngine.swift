import Foundation

public enum TerminalEngine: String, CaseIterable, Sendable {
    case ghostty
    case swiftTerm

    public static let defaultsKey = "pocketshell.terminalEngine"

    public static var current: TerminalEngine {
        if let override = ProcessInfo.processInfo.environment["PS_TERMINAL_ENGINE"],
            let engine = TerminalEngine(rawValue: override)
        {
            return engine
        }
        return UserDefaults.standard.string(forKey: defaultsKey).flatMap(TerminalEngine.init(rawValue:)) ?? .ghostty
    }

    public var title: String {
        switch self {
        case .ghostty: "libghostty"
        case .swiftTerm: "SwiftTerm"
        }
    }
}

#if os(iOS)
    import Models
    import SwiftTerm
    import UIKit

    @MainActor
    protocol TerminalEngineView: UIView {
        var multiplexerMode: Bool { get set }
        var pasteImage: (() -> Bool)? { get set }
        var onResign: (() -> Void)? { get set }
        var engineInputView: UIView? { get set }
        var terminalCols: Int { get }
        var terminalRows: Int { get }
        var isAlternateScreen: Bool { get }
        var applicationCursorKeys: Bool { get }
        var bracketedPasteMode: Bool { get }
        var mouseReportingActive: Bool { get }
        var scrolledToBottom: Bool { get }
        var selectionActive: Bool { get }
        var selectionHandleDragActive: Bool { get }
        var caretFrame: CGRect { get }
        func feedEngine(_ data: Data)
        func screenLines() -> [String]
        func scrollViewport(up lines: Int)
        func sendWheel(up: Bool, count: Int)
        func applyEngineTheme(_ theme: TerminalTheme)
        func copySelectionToPasteboard()
        func clearSelection()
        func pasteFromClipboard()
        func setRenderingSuspended(_ suspended: Bool)
        func paste(_ sender: Any?)
        func find(_ term: String, forward: Bool) -> Bool
        func clearFind()
        func grabSelectionHandle(at point: CGPoint, slop: CGFloat) -> Bool
        func dragSelectionHandle(to point: CGPoint)
        func endSelectionHandleDrag()
        func startPointerSelection(at point: CGPoint)
        func extendPointerSelection(to point: CGPoint)
        func selectWord(at point: CGPoint)
    }

    extension BottomAnchoredTerminalView: TerminalEngineView {
        var engineInputView: UIView? {
            get { inputView }
            set { inputView = newValue }
        }
        var terminalCols: Int { getTerminal().cols }
        var terminalRows: Int { getTerminal().rows }
        var isAlternateScreen: Bool { getTerminal().isCurrentBufferAlternate }
        var applicationCursorKeys: Bool { getTerminal().applicationCursor }
        var bracketedPasteMode: Bool { getTerminal().bracketedPasteMode }
        var mouseReportingActive: Bool { getTerminal().mouseMode != .off }
        var scrolledToBottom: Bool { !canScroll || scrollPosition == 1 }

        func feedEngine(_ data: Data) {
            feed(byteArray: [UInt8](data)[...])
        }

        func screenLines() -> [String] {
            let terminal = getTerminal()
            return (0..<terminal.rows).compactMap {
                terminal.getLine(row: $0)?.translateToString(trimRight: true)
                    .replacingOccurrences(of: "\u{0}", with: " ")
            }
        }

        func scrollViewport(up lines: Int) {
            if lines > 0 {
                scrollUp(lines: lines)
            } else if lines < 0 {
                scrollDown(lines: -lines)
            }
        }

        func sendWheel(up: Bool, count: Int) {
            let terminal = getTerminal()
            let flags = terminal.encodeButton(
                button: up ? 4 : 5, release: false, shift: false, meta: false, control: false)
            for _ in 0..<count {
                terminal.sendEvent(buttonFlags: flags, x: terminal.cols / 2, y: terminal.rows / 2)
            }
        }

        func applyEngineTheme(_ theme: TerminalTheme) {
            guard !SSHTerminalView.isApplied(theme, to: self) else { return }
            SSHTerminalView.apply(theme, to: self)
        }

        func copySelectionToPasteboard() {
            copy(nil)
        }

        func pasteFromClipboard() {
            paste(nil)
        }

        func find(_ term: String, forward: Bool) -> Bool {
            forward ? findNext(term) : findPrevious(term)
        }

        func clearFind() {
            clearSearch()
        }

        func startPointerSelection(at point: CGPoint) {
            startPointerSelection(at: point, rectangular: false)
        }

        func setRenderingSuspended(_ suspended: Bool) {
            layer.isHidden = suspended
            if !suspended {
                setNeedsDisplay()
            }
        }
    }
#endif
