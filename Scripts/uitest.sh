#!/bin/sh
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
DIR=$(mktemp -d)
PORT=${PS_TEST_PORT:-24222}
SIM=${PS_TEST_SIM:-iPhone 17}
TMUX_SESSION="psh-uitest-$$"
trap 'kill "$SSHD_PID" 2>/dev/null || true; tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; rm -rf "$DIR"' EXIT

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
for _ in $(seq 1 50); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    sleep 0.2
done

tmux new-session -d -s "$TMUX_SESSION" -n pshwin

cd "$REPO"
if ! xcrun simctl list devices available | grep -q "$SIM ("; then
    SIM=$(xcrun simctl list devices available | sed -n 's/^ *\(iPhone[^(]*[^ (]\) *(.*/\1/p' | head -1)
    echo "PS_TEST_SIM not available, using: $SIM"
fi
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl uninstall "$SIM" com.bl4ko.pocketshell 2>/dev/null || true
TEST_RUNNER_PS_TEST_KEY="$RAW" \
TEST_RUNNER_PS_TEST_PORT="$PORT" \
TEST_RUNNER_PS_TEST_USER="$(whoami)" \
TEST_RUNNER_PS_TEST_TMUX="$TMUX_SESSION" \
xcodebuild test \
  -scheme pocketshell \
  -destination "platform=iOS Simulator,name=$SIM" \
  -only-testing:pocketshellUITests "$@"
