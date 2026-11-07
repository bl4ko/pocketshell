#if os(iOS)
    import UIKit
    import VTKit

    @MainActor
    final class GhosttyGestureCoordinator: NSObject, UIGestureRecognizerDelegate {
        private let bridge: TerminalBridge
        private weak var view: GhosttyTerminalView?
        private var scrollTracker = PanScrollTracker(step: 1)
        private var pinchBaseSize: Double = 0
        private var lastPresenceNudge = Date.distantPast
        private(set) var selectionStart: CGPoint?
        private(set) var tap: UITapGestureRecognizer?
        var pointerHovering = false
        var openURL: (URL) -> Void = { UIApplication.shared.open($0) }
        #if !targetEnvironment(macCatalyst)
            var cursorGesture: CursorGestureController?
        #endif

        init(bridge: TerminalBridge, view: GhosttyTerminalView) {
            self.bridge = bridge
            self.view = view
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func install() {
            guard let view else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
            pan.allowedScrollTypesMask = .all
            pan.delegate = self
            view.addGestureRecognizer(pan)
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            self.tap = tap
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.cancelsTouchesInView = false
            doubleTap.delegate = self
            view.addGestureRecognizer(doubleTap)
            let tripleTap = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
            tripleTap.numberOfTapsRequired = 3
            tripleTap.cancelsTouchesInView = false
            tripleTap.delegate = self
            view.addGestureRecognizer(tripleTap)
            #if targetEnvironment(macCatalyst)
                let selectionPan = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionPan(_:)))
                selectionPan.maximumNumberOfTouches = 1
                selectionPan.delegate = self
                view.addGestureRecognizer(selectionPan)
                tap.require(toFail: selectionPan)
                let linkPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLinkPress(_:)))
                linkPress.minimumPressDuration = 0.5
                linkPress.delegate = self
                linkPress.cancelsTouchesInView = false
                view.addGestureRecognizer(linkPress)
            #endif
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            view.addGestureRecognizer(hover)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            view.addGestureRecognizer(pinch)
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleWindowSwipe(_:)))
                swipe.direction = direction
                swipe.delegate = self
                swipe.cancelsTouchesInView = false
                swipe.delaysTouchesEnded = false
                view.addGestureRecognizer(swipe)
            }
            #if !targetEnvironment(macCatalyst)
                let cursorGesture = CursorGestureController(view: view, bridge: bridge) {
                    [weak self, weak view] point in
                    guard let self, let view else { return }
                    if !self.openLink(at: point) {
                        view.selectWord(at: point)
                        view.showEditMenu(at: point)
                    }
                }
                self.cursorGesture = cursorGesture
                pan.require(toFail: cursorGesture.press)
                tap.require(toFail: cursorGesture.press)
                for gesture in view.gestureRecognizers ?? [] where gesture is UISwipeGestureRecognizer {
                    gesture.require(toFail: cursorGesture.press)
                }
            #endif
        }

        private func noteUserPresence() {
            guard Date().timeIntervalSince(lastPresenceNudge) > 2 else { return }
            lastPresenceNudge = Date()
            bridge.userInteracted?()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view else { return }
            noteUserPresence()
            let point = gesture.location(in: view)
            let focused = view.isFirstResponder
            if view.tapRaisesKeyboard(at: point) {
                _ = view.becomeFirstResponder()
            }
            if view.selectionActive, !bridge.selectMode {
                view.clearSelection()
            }
            #if !targetEnvironment(macCatalyst)
                if focused, !bridge.selectMode, view.isNearCaret(point) {
                    view.showEditMenu(at: point)
                }
            #endif
            if pointerHovering, let url = link(at: point) {
                openURL(url)
            }
            sendMouseClick(at: point)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view, !view.mouseReportingActive else { return }
            view.selectWord(at: gesture.location(in: view))
            view.showEditMenu(at: gesture.location(in: view))
        }

        @objc func handleTripleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view, !view.mouseReportingActive else { return }
            view.selectRow(at: gesture.location(in: view))
            view.showEditMenu(at: gesture.location(in: view))
        }

        func sendMouseClick(at location: CGPoint) {
            guard let view else { return }
            let (row, col) = view.cell(at: location)
            guard view.mouseReportingActive else {
                if let shortcut = CodexOptionTap.shortcut(lines: view.screenLines(), tappedRow: row) {
                    bridge.processOutgoing(Data([shortcut]))
                }
                return
            }
            view.sendMouse(button: .left, action: .press, col: col, row: row)
            view.sendMouse(button: .left, action: .release, col: col, row: row)
        }

        @objc func handleWindowSwipe(_ gesture: UISwipeGestureRecognizer) {
            guard let view, view.multiplexerMode, !bridge.selectMode, !view.selectionActive else { return }
            noteUserPresence()
            bridge.processOutgoing(Data("\u{02}\(gesture.direction == .left ? "n" : "p")".utf8))
        }

        func link(at location: CGPoint) -> URL? {
            guard let view else { return nil }
            let (row, col) = view.cell(at: location)
            if let target = view.terminal.hyperlink(at: VTPoint(col: col, row: row), tag: .viewport) {
                return URL(string: target)
            }
            let lines = view.terminal.lines(tag: .viewport, trimRight: false)
            let offset = view.terminal.lineCells(row: row, tag: .viewport).lastIndex { $0.col <= col } ?? col
            return TerminalURL.find(lines: lines, wrapped: view.wrappedRows(), row: row, column: offset)
                .flatMap(URL.init(string:))
        }

        func openLink(at location: CGPoint) -> Bool {
            guard let url = link(at: location) else { return false }
            presentLinkMenu(for: url, at: location)
            return true
        }

        private func presentLinkMenu(for url: URL, at point: CGPoint) {
            guard let view, let controller = view.window?.rootViewController else { return }
            let sheet = UIAlertController(title: url.absoluteString, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Open Link", style: .default) { _ in UIApplication.shared.open(url) })
            sheet.addAction(
                UIAlertAction(title: "Copy Link", style: .default) { _ in
                    UIPasteboard.general.string = url.absoluteString
                })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = view
            sheet.popoverPresentationController?.sourceRect = CGRect(origin: point, size: .zero)
            controller.present(sheet, animated: true)
        }

        #if targetEnvironment(macCatalyst)
            @objc func handleLinkPress(_ gesture: UILongPressGestureRecognizer) {
                guard gesture.state == .began, let view else { return }
                _ = openLink(at: gesture.location(in: view))
            }

            @objc func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
                guard let view else { return }
                if gesture.state == .cancelled || gesture.state == .failed {
                    view.endSelectionHandleDrag()
                    selectionStart = nil
                    return
                }
                guard gesture.buttonMask.contains(.primary) else { return }
                let point = gesture.location(in: view)
                switch gesture.state {
                case .began:
                    let translation = gesture.translation(in: view)
                    let press = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
                    selectionStart = press
                    if !view.grabSelectionHandle(at: press, slop: 14) {
                        view.startPointerSelection(at: press)
                        view.extendPointerSelection(to: point)
                    }
                case .changed:
                    if view.selectionHandleDragActive {
                        view.dragSelectionHandle(to: point)
                    } else {
                        view.extendPointerSelection(to: point)
                    }
                case .ended:
                    if view.selectionHandleDragActive {
                        view.dragSelectionHandle(to: point)
                        view.endSelectionHandleDrag()
                    } else {
                        view.extendPointerSelection(to: point)
                        if let start = selectionStart, hypot(point.x - start.x, point.y - start.y) < 6 {
                            view.clearSelection()
                            sendMouseClick(at: point)
                        }
                    }
                    selectionStart = nil
                default:
                    break
                }
            }
        #endif

        @objc func handleHover(_ gesture: UIHoverGestureRecognizer) {
            pointerHovering = gesture.state == .began || gesture.state == .changed
            #if targetEnvironment(macCatalyst)
                guard gesture.view?.window?.isKeyWindow == true else { return }
                noteUserPresence()
            #endif
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view else { return }
            switch gesture.state {
            case .began:
                pinchBaseSize = Double(view.font.pointSize)
            case .changed:
                let size = FontZoom.size(base: pinchBaseSize, scale: Double(gesture.scale))
                if abs(size - Double(view.font.pointSize)) >= 0.5 {
                    view.setFont(UIFont.monospacedSystemFont(ofSize: CGFloat(size.rounded()), weight: .regular))
                }
            case .ended:
                UserDefaults.standard.set(
                    Double(view.font.pointSize) / zoomScale, forKey: SSHTerminalView.Coordinator.fontSizeKey)
            default:
                break
            }
        }

        var zoomScale = 1.0

        @objc func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            if gesture.state == .began {
                noteUserPresence()
            }
            #if targetEnvironment(macCatalyst)
                guard !gesture.buttonMask.contains(.primary) else { return }
            #else
                if bridge.selectMode, view.multiplexerMode, view.mouseTracking.reportsDrag {
                    forwardSelectionDrag(gesture)
                    return
                }
                if bridge.selectMode {
                    switch gesture.state {
                    case .began:
                        let point = gesture.location(in: view)
                        let translation = gesture.translation(in: view)
                        let press = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
                        if !view.grabSelectionHandle(at: press, slop: 30) {
                            view.clearSelection()
                            view.startPointerSelection(at: press)
                            view.extendPointerSelection(to: point)
                        }
                    case .changed, .ended:
                        if view.selectionHandleDragActive {
                            view.dragSelectionHandle(to: gesture.location(in: view))
                            if gesture.state == .ended {
                                view.endSelectionHandleDrag()
                            }
                        } else {
                            view.extendPointerSelection(to: gesture.location(in: view))
                        }
                    case .cancelled, .failed:
                        view.endSelectionHandleDrag()
                    default:
                        break
                    }
                    return
                }
                if view.selectionActive, view.selectionHandleDragActive {
                    return
                }
            #endif
            switch gesture.state {
            case .began:
                scrollTracker = PanScrollTracker(step: Double(view.lineHeight))
            case .changed:
                let delta = gesture.translation(in: view).y
                gesture.setTranslation(.zero, in: view)
                let lines = scrollTracker.lines(for: Double(delta))
                guard lines != 0 else { return }
                guard view.mouseReportingActive else {
                    view.scrollViewport(up: lines)
                    return
                }
                let (row, col) = view.cell(at: gesture.location(in: view))
                view.sendMouse(
                    button: lines > 0 ? .wheelUp : .wheelDown, action: .press, col: col, row: row, count: abs(lines))
            default:
                break
            }
        }

        private func forwardSelectionDrag(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            let (row, col) = view.cell(at: point)
            switch gesture.state {
            case .began:
                let translation = gesture.translation(in: view)
                let start = view.cell(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y))
                view.sendMouse(button: .left, action: .press, col: start.col, row: start.row)
                view.sendMouse(button: .left, action: .motion, col: col, row: row)
            case .changed:
                view.sendMouse(button: .left, action: .motion, col: col, row: row)
            case .ended, .cancelled, .failed:
                view.sendMouse(button: .left, action: .release, col: col, row: row)
                bridge.selectMode = false
            default:
                break
            }
        }
    }
#endif
