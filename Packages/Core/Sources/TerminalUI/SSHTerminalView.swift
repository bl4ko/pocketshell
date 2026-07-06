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
        view.allowMouseReporting = false
        view.inputAccessoryView = nil
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleScrollPan(_:))
        )
        let gestureDelegate = SimultaneousGestureDelegate()
        pan.delegate = gestureDelegate
        context.coordinator.gestureDelegate = gestureDelegate
        view.addGestureRecognizer(pan)
        bridge.view = view
        return view
    }

    public func updateUIView(_ uiView: TerminalView, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    final class SimultaneousGestureDelegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    public final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        private let bridge: TerminalBridge
        private var scrollTracker = PanScrollTracker(step: 1)
        var gestureDelegate: SimultaneousGestureDelegate?

        init(bridge: TerminalBridge) {
            self.bridge = bridge
        }

        @objc func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
            MainActor.assumeIsolated {
                handleScrollPanOnMain(gesture)
            }
        }

        @MainActor private func handleScrollPanOnMain(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? TerminalView else { return }
            let terminal = view.getTerminal()
            guard terminal.mouseMode != .off else { return }
            switch gesture.state {
            case .began:
                scrollTracker = PanScrollTracker(step: Double(view.font.lineHeight))
            case .changed:
                let delta = gesture.translation(in: view).y
                gesture.setTranslation(.zero, in: view)
                let lines = scrollTracker.lines(for: Double(delta))
                guard lines != 0 else { return }
                let flags = terminal.encodeButton(
                    button: lines > 0 ? 4 : 5,
                    release: false,
                    shift: false,
                    meta: false,
                    control: false
                )
                let location = gesture.location(in: view)
                let col = clamp(Int(location.x / view.bounds.width * CGFloat(terminal.cols)), max: terminal.cols - 1)
                let row = clamp(Int(location.y / view.bounds.height * CGFloat(terminal.rows)), max: terminal.rows - 1)
                for _ in 0..<abs(lines) {
                    terminal.sendEvent(buttonFlags: flags, x: col, y: row)
                }
            default:
                break
            }
        }

        private func clamp(_ value: Int, max limit: Int) -> Int {
            min(max(value, 0), max(limit, 0))
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
