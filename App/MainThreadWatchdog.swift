import Foundation
import TerminalUI
import os

@MainActor
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    private init() {}

    private static let log = Logger(subsystem: "com.bl4ko.pocketshell", category: "stall")
    private var timer: Timer?
    private var last = Date()
    private var lastBytes = 0

    func start() {
        guard timer == nil else { return }
        last = Date()
        lastBytes = TerminalBridge.bytesFed
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { Self.shared.tick() }
        }
    }

    private func tick() {
        let now = Date()
        let gap = now.timeIntervalSince(last)
        last = now
        let bytes = TerminalBridge.bytesFed
        let fed = bytes - lastBytes
        lastBytes = bytes
        guard gap > 1.5 else { return }
        Self.log.error("main thread blocked \(Int(gap * 1000))ms, fed \(fed) bytes")
    }
}
