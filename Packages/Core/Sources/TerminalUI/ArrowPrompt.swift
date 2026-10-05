import Foundation

struct ArrowPrompt {
    private var visible = false
    private var missingSince: ContinuousClock.Instant?
    var needsRecheck: Bool { missingSince != nil }

    // Emit transitions only, so closing the panel manually lasts until the next prompt.
    mutating func update(lines: [String], at now: ContinuousClock.Instant = .now) -> Bool? {
        let footer = lines.suffix(6).joined(separator: " ").lowercased()
        // ponytail: Match explicit footer hints; add phrases when other TUIs need support.
        let next =
            ["enter to select", "enter to confirm", "enter to submit"].contains { footer.contains($0) }
            && ["↑/↓", "↑↓", "←/→", "up/down", "arrow keys"].contains { footer.contains($0) }
            && (footer.contains("navigate") || footer.contains("to select"))
        // Resizing the keyboard or repainting a TUI can briefly erase the footer.
        if !next, visible {
            if let missingSince {
                guard missingSince.duration(to: now) >= .milliseconds(500) else { return nil }
            } else {
                missingSince = now
                return nil
            }
        }
        missingSince = nil
        guard next != visible else { return nil }
        visible = next
        return next
    }
}
