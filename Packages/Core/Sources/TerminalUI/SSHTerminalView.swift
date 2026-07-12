#if os(iOS)
import Models
import SwiftTerm
import SwiftUI
import UIKit

extension UIColor {
    convenience init(_ rgb: RGBColor) {
        self.init(
            red: CGFloat(rgb.red) / 255,
            green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255,
            alpha: 1
        )
    }
}

public struct SSHTerminalView: UIViewRepresentable {
    private let bridge: TerminalBridge
    private let theme: TerminalTheme

    public init(bridge: TerminalBridge, theme: TerminalTheme = .defaultTheme) {
        self.bridge = bridge
        self.theme = theme
    }

    static func apply(_ theme: TerminalTheme, to view: TerminalView) {
        if let background = RGBColor(hex: theme.background) {
            view.backgroundColor = UIColor(background)
            view.nativeBackgroundColor = UIColor(background)
        }
        if let foreground = RGBColor(hex: theme.foreground) {
            view.nativeForegroundColor = UIColor(foreground)
        }
        if let cursor = RGBColor(hex: theme.cursor) {
            view.caretColor = UIColor(cursor)
        }
        let colors = theme.ansi.compactMap { RGBColor(hex: $0) }.map {
            SwiftTerm.Color(
                red: UInt16($0.red) * 257,
                green: UInt16($0.green) * 257,
                blue: UInt16($0.blue) * 257
            )
        }
        if colors.count == 16 {
            view.installColors(colors)
        }
    }

    public func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        Self.apply(theme, to: view)
        context.coordinator.appliedTheme = theme.name
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
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        view.addGestureRecognizer(pinch)
        let saved = UserDefaults.standard.double(forKey: Coordinator.fontSizeKey)
        if FontZoom.range.contains(saved) {
            view.font = UIFont.monospacedSystemFont(ofSize: CGFloat(saved), weight: .regular)
        }
        bridge.view = view
        return view
    }

    public func updateUIView(_ uiView: TerminalView, context: Context) {
        if context.coordinator.appliedTheme != theme.name {
            Self.apply(theme, to: uiView)
            context.coordinator.appliedTheme = theme.name
        }
    }

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
        var appliedTheme: String?

        init(bridge: TerminalBridge) {
            self.bridge = bridge
        }

        static let fontSizeKey = "pocketshell.terminalFontSize"
        private var pinchBaseSize: Double = 0

        @objc func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
            MainActor.assumeIsolated {
                handleScrollPanOnMain(gesture)
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            MainActor.assumeIsolated {
                handlePinchOnMain(gesture)
            }
        }

        @MainActor private func handlePinchOnMain(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view as? TerminalView else { return }
            switch gesture.state {
            case .began:
                pinchBaseSize = Double(view.font.pointSize)
            case .changed:
                let size = FontZoom.size(base: pinchBaseSize, scale: Double(gesture.scale))
                if abs(size - Double(view.font.pointSize)) >= 0.5 {
                    view.font = UIFont.monospacedSystemFont(ofSize: CGFloat(size.rounded()), weight: .regular)
                }
            case .ended:
                UserDefaults.standard.set(Double(view.font.pointSize), forKey: Self.fontSizeKey)
            default:
                break
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

        private func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
            if Thread.isMainThread {
                MainActor.assumeIsolated { work() }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { work() }
                }
            }
        }

        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let payload = Data(data)
            let bridge = bridge
            onMain {
                bridge.processOutgoing(payload)
            }
        }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let bridge = bridge
            onMain {
                bridge.resizeHost?(newCols, newRows)
            }
        }

        public func setTerminalTitle(source: TerminalView, title: String) {}
        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        public func scrolled(source: TerminalView, position: Double) {}
        public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            onMain {
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
