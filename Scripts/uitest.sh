#!/bin/sh
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
DIR=$(mktemp -d)
PORT=${PS_TEST_PORT:-24222}
trap 'kill "$SSHD_PID" 2>/dev/null || true; rm -rf "$DIR"' EXIT

swift "$REPO/Scripts/gen-test-key.swift" > "$DIR/key.txt"
RAW=$(sed -n 1p "$DIR/key.txt")
PUB=$(sed -n 2p "$DIR/key.txt")

ssh-keygen -t ed25519 -N "" -f "$DIR/host_ed25519" -q
printf '%s\n' "$PUB" > "$DIR/authorized_keys"
chmod 600 "$DIR/authorized_keys"

cat > "$DIR/sshd_config" << EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $DIR/host_ed25519
PidFile $DIR/sshd.pid
AuthorizedKeysFile $DIR/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
LogLevel QUIET
EOF

/usr/sbin/sshd -D -f "$DIR/sshd_config" &
SSHD_PID=$!
sleep 1

cd "$REPO"
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcrun simctl uninstall "iPhone 17" com.bl4ko.pocketshell 2>/dev/null || true
TEST_RUNNER_PS_TEST_KEY="$RAW" \
TEST_RUNNER_PS_TEST_PORT="$PORT" \
TEST_RUNNER_PS_TEST_USER="$(whoami)" \
xcodebuild test \
  -scheme pocketshell \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:pocketshellUITests "$@"
