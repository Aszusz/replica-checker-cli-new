#!/usr/bin/env bash
set -euo pipefail

# Automates this JeDI sequence against the local Domino server:
#   telnet 0 1910
#   Glogin admin pass
#   Gconsole <fqdn>
#   Ctell genesis info
#   Glogout

command -v expect >/dev/null 2>&1 || { echo "ERROR: expect is required (apt install expect)" >&2; exit 1; }

FQDN=$(hostname -f)

expect <<EOF
log_user 1
set timeout 10
spawn telnet 0 1910
expect "250-"
send "Glogin admin pass\r"
expect "204-"
send "Gconsole $FQDN\r"
expect "210-"
send "Ctell genesis info\r"
sleep 5
send "Glogout\r"
expect eof
EOF
