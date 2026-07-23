#!/bin/sh
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
DIR=$(mktemp -d)
PORT=${PS_TEST_PORT:-24222}
SIM=${PS_TEST_SIM:-iPhone 17}
TMUX_SESSION="psh-uitest-$$"
STATUS_STABLE="$TMUX_SESSION-stable"
STATUS_CHURN="$TMUX_SESSION-churn"
STATUS_GAP="$TMUX_SESSION-gap"
cleanup() {
    kill "${SSHD_PID:-}" 2>/dev/null || true
    for session in "$TMUX_SESSION" "$STATUS_STABLE" "$STATUS_CHURN" "$STATUS_GAP"; do
        tmux kill-session -t "$session" 2>/dev/null || true
    done
    rm -rf "$DIR"
}
trap cleanup EXIT

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
cat > "$DIR/codex.c" << 'EOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "stable";
    for (int i = 0;; i++) {
        printf("\033[2J\033[H");
        if (strcmp(mode, "churn") == 0) {
            printf("background update %d\nctx: 14%% used / 86%% left\n", i);
        } else if (strcmp(mode, "gap") == 0 && i % 20 >= 8) {
            printf("agent redraw frame %d\n", i);
        } else {
            printf("finished agent\nctx: 14%% used / 86%% left\n");
        }
        fflush(stdout);
        sleep(1);
    }
}
EOF
cc -O2 -o "$DIR/codex" "$DIR/codex.c"
tmux new-session -d -s "$STATUS_STABLE" -n stable "$DIR/codex stable"
tmux new-session -d -s "$STATUS_CHURN" -n churn "$DIR/codex churn"
tmux new-session -d -s "$STATUS_GAP" -n gap "$DIR/codex gap"
tmux set-option -t "$STATUS_STABLE" automatic-rename off
tmux set-option -t "$STATUS_CHURN" automatic-rename off
tmux set-option -t "$STATUS_GAP" automatic-rename off

cd "$REPO"
if ! xcrun simctl list devices available | grep -q "$SIM ("; then
    SIM=$(xcrun simctl list devices available | sed -n 's/^ *\(iPhone[^(]*[^ (]\) *(.*/\1/p' | head -1)
    echo "PS_TEST_SIM not available, using: $SIM"
fi
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl uninstall "$SIM" com.bl4ko.pocketshell 2>/dev/null || true
if [ "$#" -eq 0 ]; then
    set -- "-only-testing:pocketshellUITests"
fi
TEST_RUNNER_PS_TEST_KEY="$RAW" \
TEST_RUNNER_PS_TEST_PORT="$PORT" \
TEST_RUNNER_PS_TEST_USER="$(whoami)" \
TEST_RUNNER_PS_TEST_TMUX="$TMUX_SESSION" \
TEST_RUNNER_PS_TEST_STATUS_STABLE="$STATUS_STABLE" \
TEST_RUNNER_PS_TEST_STATUS_CHURN="$STATUS_CHURN" \
TEST_RUNNER_PS_TEST_STATUS_GAP="$STATUS_GAP" \
xcodebuild test \
  -scheme pocketshell \
  -destination "platform=iOS Simulator,name=$SIM" \
  "$@"
