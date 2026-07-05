#if os(iOS)
import SwiftTerm
import SwiftUI
import UIKit

public struct SSHTerminalView: UIViewRepresentable {
    private let bridge: TerminalBridge

    public init(bridge: TerminalBridge) {
        self.bridge = bridge
    }

    public func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        view.backgroundColor = .black
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        bridge.view = view
        return view
    }

    public func updateUIView(_ uiView: TerminalView, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    public final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        private let bridge: TerminalBridge

        init(bridge: TerminalBridge) {
            self.bridge = bridge
        }

        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let payload = Data(data)
            MainActor.assumeIsolated {
                bridge.processOutgoing(payload)
            }
        }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                bridge.resizeHost?(newCols, newRows)
            }
        }

        public func setTerminalTitle(source: TerminalView, title: String) {}
        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        public func scrolled(source: TerminalView, position: Double) {}
        public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                UIApplication.shared.open(url)
            }
        }
        public func bell(source: TerminalView) {}
        public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        public func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }
    }
}
#endif
