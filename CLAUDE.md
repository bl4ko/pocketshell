# CLAUDE.md

Guidance for AI coding agents and contributors working in this repository. `AGENTS.md` is a symlink to this file.

## What this is

iOS SSH terminal + VNC app (SwiftUI, iOS 17+) for managing tmux-based agent sessions from iPhone. Companion watchOS app and home/lock-screen widget. Commits use conventional format (`<type>(<scope>): <subject>`).

## Commands

```sh
xcodegen generate                                  # regenerate pocketshell.xcodeproj (required after project.yml edits; .xcodeproj is gitignored)
swift test --package-path Packages/Core            # all unit + sshd integration tests (fast, no simulator)
swift test --package-path Packages/Core --filter TmuxKitTests            # one test target
swift test --package-path Packages/Core --filter TabStatusResolverTests/holdsPreviousStatus  # one test
swift build --package-path Packages/Core           # compile check without tests
./Scripts/uitest.sh                                # e2e UI tests: throwaway sshd + tmux session + simulator
xcodebuild build -scheme pocketshell -destination "generic/platform=iOS Simulator"  # full app build
pre-commit run --all-files                         # format + lint + Core tests (hooks: pre-commit install)
```

- Warnings are errors everywhere: `SWIFT_TREAT_WARNINGS_AS_ERRORS` in `project.yml`, `.treatAllWarnings(as: .error)` in `Package.swift`. Any warning fails the build.
- Formatting is enforced by toolchain `swift format` via pre-commit (`.swift-format`: 4-space indent, line length 120). Run `swift format --in-place --recursive <paths>` before committing if hooks are not installed.
- Coverage: `swift test --package-path Packages/Core --enable-code-coverage`, then `xcrun llvm-cov report "$(swift build --package-path Packages/Core --show-bin-path)/CorePackageTests.xctest/Contents/MacOS/CorePackageTests" -instr-profile "$(swift build --package-path Packages/Core --show-bin-path)/codecov/default.profdata" -ignore-filename-regex='(Tests|checkouts)'`.

## Testing

- SSHKit integration tests are `#if os(macOS)`: they spawn a real `/usr/sbin/sshd` on a random localhost port (`TestSSHD` in `SSHConnectionIntegrationTests.swift`) and run as part of plain `swift test`.
- `Scripts/uitest.sh` generates a client key (`Scripts/gen-test-key.swift`), starts a throwaway sshd plus a detached tmux fixture session, and passes `PS_TEST_KEY`/`PS_TEST_PORT`/`PS_TEST_USER`/`PS_TEST_TMUX` into the UI tests via `TEST_RUNNER_` env vars. Tests skip themselves if those are unset. Simulator defaults to iPhone 17; override with `PS_TEST_SIM`, falls back to first available iPhone.
- UI tests in `UITests/SmokeUITests.swift` are order-dependent (XCTest runs alphabetically): `testAddHostAndRunExecSnippet` creates the `localbox` host that later tests reuse.
- UIKit-gated sources (`TerminalBridge`, `SSHTerminalView`, VNC views, `TerminalToolbar`) do not compile into macOS `swift test` — they are covered only by UI tests. Terminal screen content is not accessibility-visible (SwiftTerm draws directly), so e2e asserts toolbar presence and absence of error text, not screen text.
- New tests: unit tests go next to the module in `Packages/Core/Tests/<Module>Tests/`; e2e flows go in `UITests/SmokeUITests.swift` with an accessibility identifier on any new tappable control.

## Architecture

Thin app targets, all logic in `Packages/Core` (local SPM package, one library per concern):

- **Models** — value types shared by every target (Host, Snippet, SessionSnapshot, ConfigExport, themes, toolbar keys, VNC config). Watch + Widget depend only on this.
- **KeyKit** — Secure Enclave P-256 device key with software Keychain fallback, OpenSSH public/private key encoding (incl. bcrypt-pbkdf for encrypted keys), password vault.
- **SSHKit** — swift-nio-ssh connection, TOFU known-hosts store, port forwarding, SFTP session, chunked-base64-exec remote file upload. Depends on KeyKit + SFTPKit.
- **SFTPKit** — pure SFTPv3 packet encode/decode (no IO).
- **TmuxKit** — tmux command building and output parsing (session/window/pane listing, dashboard previews, send-keys).
- **MonitorKit** — `TabStatusResolver` (busy/idle/needs-input from screen-text diffs) and `AgentActivityTracker` (agent-finished notifications).
- **ReconnectKit** — auto-reconnect state machine with backoff.
- **TerminalUI** — SwiftTerm wrapper (`SSHTerminalView`, `TerminalBridge`), feed gating, font zoom, pan/scroll tracking.
- **ToolbarUI** — special-keys toolbar, key-sequence encoder, user-editable via `toolbar.json`.
- **VNCKit** — RoyalVNCKit session controller, screen view, pointer math, key combos (ARD auth).
- **LockKit** — Face ID app lock gate.

`App/` is SwiftUI glue: screens, stores, `ConnectionController` (owns SSH lifecycle per host), `SessionMonitor` (5s polling), `WatchRelay` (WatchConnectivity). `WatchApp/` and `Widget/` are separate targets sharing app group `group.com.bl4ko.pocketshell`.

New code goes in a Core module with tests, not in `App/`, unless it is pure UI glue.

## Hard-won gotchas (do not re-learn)

- **Tab status detection**: marker heuristics alone flap on narrow wrapped screens, so `TabStatusResolver` diffs screen text between 5s polls. User keystrokes echo = screen change, so `TerminalBridge` flags typed-since-poll and the resolver holds the previous status. SwiftTerm auto-replies (cursor position, color queries — emitted synchronously during `feed` on every TUI redraw) exit through the same `send` delegate as keystrokes; they must NOT set the typed flag or the active tab's status freezes forever (`feedingView` guard in `TerminalBridge`). Mid-redraw frames lack footer markers, so one markerless sample is held (2 consecutive = clear). Codex idle is detected via `\d+% (context left|used)` footer regex.
- **Hidden tabs** live in a ZStack: `allowsHitTesting(false)` blocks touches but NOT first responder. Tab switch focuses the selected TerminalView; `becomeFirstResponder` auto-resigns the old one — never resign-then-become (keyboard dismiss/present jank).
- **Keyboard bottom padding** applies to the ACTIVE tab only and without animation — animated padding reflows SwiftTerm every frame on every tab (lag + PTY resize storms).
- **Clipboard image paste** uploads to remote `/tmp/psh-*.jpg` via chunked base64 exec and inserts the path; toolbar paste button appears for image-only clipboard.
