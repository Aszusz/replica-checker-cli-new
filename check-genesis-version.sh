#!/usr/bin/env bash
set -euo pipefail

# check-genesis-version.sh
# Print the current Genesis version on the local Domino server.
# Read-only: does not load Genesis if it is not running.

CONSOLE_LOG="/local/notesdata/IBM_TECHNICAL_SUPPORT/console.log"

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[[ -f "$CONSOLE_LOG" ]] || fail "Console log not found at $CONSOLE_LOG"

marker=$(wc -l < "$CONSOLE_LOG")

sudo -u domino bash -c \
    'cd /local/notesdata && /opt/hcl/domino/bin/server -c "tell genesis info"' \
    >/dev/null 2>&1 \
    || fail "Failed to send command to Domino server (is it running?)"

sleep 3

output=$(tail -n +$((marker + 1)) "$CONSOLE_LOG")

if echo "$output" | grep -q "Genesis:.*version"; then
    echo "$output" | grep -m1 "version" | sed 's/.*version[[:space:]]*//' | awk '{print $1}'
else
    fail "Genesis is not running"
fi
