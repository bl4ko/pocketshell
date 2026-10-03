#if os(iOS) && !targetEnvironment(macCatalyst)
    import SwiftTerm
    import UIKit

    @MainActor
    final class CursorGestureController: NSObject, UIGestureRecognizerDelegate {
        private weak var view: TerminalView?
        private let bridge: TerminalBridge
        private let onStationaryPress: (CGPoint) -> Void
        private var origin = CGPoint.zero
        private var movement: CursorGesture.Movement?
        private var repeatGate = CursorGesture.RepeatGate()
        private var repeatTask: Task<Void, Never>?
        private var selecting = false
        private var moved = false
        private let indicator = UILabel()
        let press: UILongPressGestureRecognizer

        init(view: TerminalView, bridge: TerminalBridge, onStationaryPress: @escaping (CGPoint) -> Void) {
            self.view = view
            self.bridge = bridge
            self.onStationaryPress = onStationaryPress
            press = UILongPressGestureRecognizer()
            super.init()
            // SwiftTerm's word-selection hold would otherwise claim this touch midway through a drag.
            for gesture in view.gestureRecognizers ?? [] where gesture is UILongPressGestureRecognizer {
                view.removeGestureRecognizer(gesture)
            }
            press.minimumPressDuration = 0.4
            press.numberOfTouchesRequired = 1
            press.delegate = self
            press.addTarget(self, action: #selector(handlePress(_:)))
            view.addGestureRecognizer(press)
            indicator.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)
            indicator.textAlignment = .center
            indicator.textColor = .white
            indicator.backgroundColor = .black.withAlphaComponent(0.75)
            indicator.layer.cornerRadius = 12
            indicator.clipsToBounds = true
            indicator.isUserInteractionEnabled = false
            indicator.isHidden = true
            indicator.accessibilityIdentifier = "terminal.cursorGesture"
            view.addSubview(indicator)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { false }

        @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            let windowPoint = gesture.location(in: view.window)
            switch gesture.state {
            case .began:
                origin = windowPoint
                moved = false
                selecting = bridge.selectMode || view.selectionActive
                bridge.userInteracted?()
                if selecting {
                    if !view.grabSelectionHandle(at: point) { view.selectWord(at: point) }
                    return
                }
                indicator.frame = CGRect(x: view.bounds.minX + 12, y: view.bounds.minY + 12, width: 104, height: 52)
                indicator.text = "← ↑ ↓ →"
                indicator.isHidden = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                repeatTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled, let self else { break }
                        guard self.view?.window != nil, self.view?.layer.isHidden == false else {
                            self.stop()
                            break
                        }
                        self.sendPendingKey()
                    }
                }
            case .changed:
                if selecting {
                    if view.selectionHandleDragActive {
                        view.dragSelectionHandle(to: point)
                    } else {
                        view.extendPointerSelection(to: point)
                    }
                    return
                }
                let next = CursorGesture.movement(
                    x: Double(windowPoint.x - origin.x), y: Double(windowPoint.y - origin.y))
                if let next {
                    moved = true
                    indicator.text = "\(next.symbol)  \(String(repeating: "›", count: next.speed))"
                } else {
                    indicator.text = "← ↑ ↓ →"
                }
                movement = next
                sendPendingKey()
            case .ended:
                let stationary = !moved && !selecting
                stop()
                view.endSelectionHandleDrag()
                if stationary { onStationaryPress(point) }
            case .cancelled, .failed:
                stop()
                view.endSelectionHandleDrag()
            default:
                break
            }
        }

        private func sendPendingKey() {
            if let action = repeatGate.key(for: movement, at: ProcessInfo.processInfo.systemUptime) {
                bridge.handleToolbar(action)
            }
        }

        private func stop() {
            repeatTask?.cancel()
            repeatTask = nil
            movement = nil
            repeatGate = CursorGesture.RepeatGate()
            indicator.isHidden = true
        }
    }
#endif
