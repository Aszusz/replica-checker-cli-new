#!/usr/bin/env bash
set -euo pipefail

# Automates this JeDI sequence against the local Domino server:
#   telnet 0 1910
#   Glogin admin pass
#   Gstatus              (auto-discover the JeDI server UID; abort if not RUNNING)
#   Gconsole <UID>
#   Ctell genesis info   (filtered to just the Genesis response lines)
#   Glogout

command -v expect >/dev/null 2>&1 || { echo "ERROR: expect is required (apt install expect)" >&2; exit 1; }

expect <<'EOF'
log_user 0
set timeout 10

spawn telnet 0 1910
expect -re "(250-\[^\n]*)\n"
send_user "$expect_out(1,string)\n"

send_user ">>> Glogin admin pass\n"
send "Glogin admin pass\r"
expect -re "(204-\[^\n]*)\n"
send_user "$expect_out(1,string)\n"

send_user ">>> Gstatus\n"
send "Gstatus\r"
expect -re "Configured domino servers:"
expect -re "(240- (\\S+): (\\S+)\[^\n]*)\n"
set line $expect_out(1,string)
set uid $expect_out(2,string)
set state $expect_out(3,string)
send_user "$line\n"

if {$state ne "RUNNING"} {
    send_user "ERROR: server $uid is $state, not RUNNING — aborting\n"
    exit 1
}

send_user ">>> Gconsole $uid\n"
send "Gconsole $uid\r"
expect -re "(210-\[^\n]*)\n"
send_user "$expect_out(1,string)\n"

# Gconsole replays recent console history on attach; drain it
# silently so we only show the live response to our `tell`.
send_user "(draining scrollback...)\n"
set timeout 2
expect {
    -re "(?s).+" { exp_continue }
    timeout {}
}
set timeout 30

send_user ">>> Ctell genesis info\n"
send "Ctell genesis info\r"
while {1} {
    expect {
        -re "(Genesis: \[^\n]+)\n" {
            send_user "$expect_out(1,string)\n"
            if {[regexp {^Genesis: catalog} $expect_out(1,string)]} {
                break
            }
        }
        timeout {
            send_user "ERROR: timeout waiting for Genesis response\n"
            exit 1
        }
    }
}

send_user ">>> Glogout\n"
send "Glogout\r"
expect -re "(251-\[^\n]*)\n"
send_user "$expect_out(1,string)\n"
EOF
