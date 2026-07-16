# pocketshell

iOS SSH terminal + VNC client for managing tmux-based AI agent sessions (Claude Code, Codex, opencode) from your iPhone. Includes a watchOS companion app and a home/lock-screen widget.

Built for one workflow: agents run in tmux on a machine at home, you check on them, answer their prompts, and kick off new work from wherever you are.

## Features

**Terminal**
- Full SSH terminal (SwiftTerm) with tabs — one tab per tmux window, one tap to attach
- Agent status per tab: busy / idle / needs-input, detected from screen activity
- Notification when an agent finishes while you're in another tab
- Special-keys toolbar (esc, ctrl, tab, arrows, custom sequences), editable via `toolbar.json`
- Snippets: type into the terminal or exec-and-show-output
- Paste images from the clipboard — uploaded to the remote host, path inserted at the cursor
- Font zoom, themes, auto-reconnect with backoff on network change or foregrounding

**Security**
- Secure Enclave P-256 device key (software Keychain fallback); export the public key from the Keys screen
- Import existing OpenSSH ed25519/P-256 keys, including passphrase-encrypted ones
- TOFU host-key pinning — key mismatch refuses to connect
- Passwords stored in the Keychain, optional Face ID app lock

**Beyond the terminal**
- VNC remote desktop (RoyalVNCKit), incl. macOS Screen Sharing with ARD auth
- watchOS app: glanceable session status on your wrist
- Widget: agent session status on the home/lock screen

## Requirements

- iOS 17+, Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A host running `tmux` that you can reach over SSH

## Install

```sh
git clone https://github.com/bl4ko/pocketshell
cd pocketshell
xcodegen generate
open pocketshell.xcodeproj
```

In Xcode: select your device, set your signing team (with a free Apple ID the app must be re-installed every 7 days), and Run. Then open the Keys screen in the app and add the device public key to `~/.ssh/authorized_keys` on your hosts.

## Development

```sh
swift test --package-path Packages/Core   # unit + sshd integration tests (no simulator needed)
./Scripts/uitest.sh                       # e2e UI tests against a throwaway sshd + tmux
```

Architecture, testing workflow, and contributor guidance live in [CLAUDE.md](CLAUDE.md) (`AGENTS.md` symlinks to it).
