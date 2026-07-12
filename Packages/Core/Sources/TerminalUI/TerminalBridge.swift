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
    private var gate = FeedGate()
    private var flushTask: Task<Void, Never>?
    private var userInputPending = false

    public init() {}

    public func feed(_ data: Data) {
        if let out = gate.ingest(data) {
            view?.feed(byteArray: [UInt8](out)[...])
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
            view?.feed(byteArray: [UInt8](out)[...])
        }
    }

    private func flushPending() {
        flushTask = nil
        if let out = gate.drain() {
            view?.feed(byteArray: [UInt8](out)[...])
        }
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
        let pasteboard = UIPasteboard.general
        if let imagePaste, !pasteboard.hasStrings,
           let image = pasteboard.image,
           let data = image.jpegData(compressionQuality: 0.85) {
            imagePaste(data)
            return
        }
        view?.paste(nil)
    }

    public func copySelection() {
        view?.copy(nil)
    }

    public func consumeUserInput() -> Bool {
        defer { userInputPending = false }
        return userInputPending
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
            userInputPending = true
            sendToHost?(data)
        }
    }

    public func processOutgoing(_ data: Data) {
        userInputPending = true
        if ctrlActive,
           let text = String(data: data, encoding: .utf8),
           text.count == 1,
           let character = text.first,
           let ctrl = ToolbarKeyEncoder.applyCtrl(to: character) {
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
