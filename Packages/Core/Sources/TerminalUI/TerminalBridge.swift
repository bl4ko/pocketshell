#if os(iOS)
import Foundation
import Models
import SwiftTerm
import ToolbarUI

@MainActor
public final class TerminalBridge: ObservableObject {
    @Published public var ctrlActive = false
    public var sendToHost: ((Data) -> Void)?
    public var resizeHost: ((_ cols: Int, _ rows: Int) -> Void)?
    weak var view: TerminalView?

    public init() {}

    public func feed(_ data: Data) {
        view?.feed(byteArray: [UInt8](data)[...])
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
