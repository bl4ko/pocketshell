# pocketshell

Personal iOS SSH terminal for managing tmux-based Claude agent sessions from iPhone.

## Stack

- SwiftUI app, iOS 17+, XcodeGen project (`xcodegen generate`)
- `Packages/Core` local SPM package: Models, KeyKit, SSHKit, ReconnectKit, TmuxKit, TerminalUI, ToolbarUI
- SSH: swift-nio-ssh. Terminal emulation: SwiftTerm.

## Features (v1)

- Hosts with per-host tmux session: connect lists windows, one tap attaches
- Secure Enclave P-256 device key (software Keychain fallback), OpenSSH pubkey export from Keys screen
- TOFU host-key pinning, mismatch refuses connection
- Auto-reconnect with backoff on network change/foreground, tmux re-attach
- Special-keys toolbar (esc/ctrl/tab/arrows/custom sequences), user-editable via `toolbar.json`
- Snippets: type-into-terminal or exec-with-output (host context menu)

## Develop

```sh
xcodegen generate
swift test --package-path Packages/Core   # unit + sshd integration tests
./Scripts/uitest.sh                       # UI smoke tests against throwaway sshd
```

## Install on iPhone

Open `pocketshell.xcodeproj` in Xcode, select your device, set your team (free Apple ID: re-sign every 7 days), Run. Then copy the device public key from the Keys screen into `~/.ssh/authorized_keys` on target hosts.
