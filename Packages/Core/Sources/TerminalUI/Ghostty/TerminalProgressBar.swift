#if os(iOS)
    import UIKit
    import VTKit

    final class TerminalProgressBar: UIView {
        private(set) var fraction: CGFloat?
        private(set) var color = UIColor.systemBlue
        private let bar = CALayer()
        private var lastPercent: Int?
        private var expiry: Timer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isHidden = true
            isUserInteractionEnabled = false
            layer.masksToBounds = true
            layer.addSublayer(bar)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("not used from a storyboard")
        }

        deinit {
            MainActor.assumeIsolated { expiry?.invalidate() }
        }

        func apply(_ progress: VTProgress) {
            expiry?.invalidate()
            expiry = nil
            switch progress.state {
            case .remove:
                lastPercent = nil
                fraction = nil
                isHidden = true
                bar.removeAllAnimations()
                return
            case .set: lastPercent = progress.percent ?? 0
            case .error, .pause: lastPercent = progress.percent ?? lastPercent ?? (progress.state == .pause ? 100 : nil)
            case .indeterminate: lastPercent = nil
            }
            fraction = progress.state == .indeterminate ? nil : lastPercent.map { CGFloat($0) / 100 }
            color =
                switch progress.state {
                case .error: .systemRed
                case .pause: .systemOrange
                default: .systemBlue
                }
            isHidden = false
            expiry = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(VTProgress(state: .remove, percent: nil)) }
            }
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !isHidden else { return }
            backgroundColor = fraction == nil ? color.withAlphaComponent(0.3) : .clear
            bar.backgroundColor = color.cgColor
            bar.removeAllAnimations()
            guard let fraction else {
                let width = bounds.width / 4
                bar.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
                let slide = CABasicAnimation(keyPath: "position.x")
                slide.fromValue = width / 2
                slide.toValue = bounds.width - width / 2
                slide.duration = 1.2
                slide.autoreverses = true
                slide.repeatCount = .infinity
                bar.add(slide, forKey: "slide")
                return
            }
            bar.frame = CGRect(x: 0, y: 0, width: bounds.width * min(max(fraction, 0), 1), height: bounds.height)
        }
    }
#endif
