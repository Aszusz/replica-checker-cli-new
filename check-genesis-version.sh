#!/usr/bin/env bash
set -euo pipefail

# Prints the local Domino server's Genesis info via JeDI.
# Built on session.sh — the handshake (telnet/Glogin/Gstatus/Gconsole/Glogout)
# is handled there. Aborts if the discovered server isn't RUNNING.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/session.sh"

trap session_close EXIT
session_open

session_send_console --cmd "tell genesis info" --until "^Genesis: catalog" \
    | grep '^Genesis: '

session_close
