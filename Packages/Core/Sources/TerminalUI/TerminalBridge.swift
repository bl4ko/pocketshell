#if os(iOS)
    import Foundation
    import Models
    import SwiftTerm
    import ToolbarUI
    import UIKit

    @MainActor
    public final class TerminalBridge: ObservableObject {
        @Published public var ctrlActive = false
        public var sendToHost: ((Data) -> Void)?
        public var resizeHost: ((_ cols: Int, _ rows: Int) -> Void)?
        public var imagePaste: ((Data) -> Void)?
        weak var view: TerminalView?
        private var theme: TerminalTheme?
        private var gate = FeedGate()
        private var flushTask: Task<Void, Never>?

        public init() {}

        public func feed(_ data: Data) {
            if let out = gate.ingest(data) {
                feedView(out)
            } else if flushTask == nil {
                flushTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.flushPending()
                }
            }
        }

        public func setLive(_ live: Bool) {
            flushTask?.cancel()
            flushTask = nil
            if let out = gate.setLive(live) {
                feedView(out)
            }
        }

        private func flushPending() {
            flushTask = nil
            if let out = gate.drain() {
                feedView(out)
            }
        }

        private func feedView(_ out: Data) {
            guard let view else { return }
            view.feed(byteArray: [UInt8](out)[...])
            if let theme, !SSHTerminalView.isApplied(theme, to: view) {
                SSHTerminalView.apply(theme, to: view)
            }
        }

        func setTheme(_ theme: TerminalTheme) {
            self.theme = theme
            guard let view, !SSHTerminalView.isApplied(theme, to: view) else { return }
            SSHTerminalView.apply(theme, to: view)
        }

        public func visibleText() -> String {
            flushTask?.cancel()
            flushPending()
            guard let terminal = view?.getTerminal() else { return "" }
            return (0..<terminal.rows)
                .compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
                .joined(separator: "\n")
                .replacingOccurrences(of: "\u{0}", with: " ")
        }

        public func paste() {
            view?.paste(nil)
        }

        func pasteImage() -> Bool {
            guard let imagePaste else { return false }
            let pasteboard = UIPasteboard.general
            let image =
                pasteboard.image
                ?? pasteboard.url.flatMap { UIImage(contentsOfFile: $0.path) }
                ?? pasteboard.string.flatMap(URL.init(string:)).flatMap {
                    $0.isFileURL ? UIImage(contentsOfFile: $0.path) : nil
                }
            guard let data = image?.jpegData(compressionQuality: 0.85) else { return false }
            imagePaste(data)
            return true
        }

        public func copySelection() {
            view?.copy(nil)
        }

        public var isTerminalFocused: Bool {
            view?.isFirstResponder ?? false
        }

        public func setTerminalFocused(_ focused: Bool) {
            guard let view else { return }
            if focused {
                _ = view.becomeFirstResponder()
            } else if view.isFirstResponder {
                _ = view.resignFirstResponder()
            }
        }

        public func toggleKeyboard() {
            guard let view else { return }
            if view.isFirstResponder {
                _ = view.resignFirstResponder()
            } else {
                _ = view.becomeFirstResponder()
            }
        }

        public func handleToolbar(_ action: ToolbarKey.Action) {
            if case .ctrlModifier = action {
                ctrlActive.toggle()
                return
            }
            if let data = ToolbarKeyEncoder.data(for: action) {
                sendToHost?(data)
            }
        }

        public func processOutgoing(_ data: Data) {
            if ctrlActive,
                let text = String(data: data, encoding: .utf8),
                text.count == 1,
                let character = text.first,
                let ctrl = ToolbarKeyEncoder.applyCtrl(to: character)
            {
                ctrlActive = false
                sendToHost?(ctrl)
                return
            }
            sendToHost?(data)
        }

        public var currentSize: (cols: Int, rows: Int) {
            guard let view else { return (80, 24) }
            return (view.getTerminal().cols, view.getTerminal().rows)
        }
    }
#endif
