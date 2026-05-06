#!/usr/bin/env bash
set -euo pipefail

# check-genesis-version.sh
# Connects to JeDI on localhost:1910 and prints the Genesis addin
# version from the local Domino server. If Domino isn't running,
# starts it first via Gstart.

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

command -v expect >/dev/null 2>&1 || fail "expect is required (apt install expect)"

FQDN=$(hostname -f 2>/dev/null || hostname)
[[ -n "$FQDN" ]] || fail "Could not determine local FQDN"

# Single-quoted heredoc keeps bash from interpolating Tcl/expect vars.
# FQDN_PLACEHOLDER is substituted below.
EXPECT_SCRIPT=$(cat <<'EOEXPECT'
log_user 0
set timeout 30
set fqdn "FQDN_PLACEHOLDER"

spawn telnet localhost 1910
expect {
    -re "250-" {}
    timeout { puts stderr "JeDI banner timeout"; exit 2 }
    eof     { puts stderr "Connection closed before banner"; exit 2 }
}

send "Glogin admin pass\r"
expect {
    -re "204-" {}
    -re "550-" { puts stderr "JeDI login rejected"; exit 2 }
    timeout    { puts stderr "Login timeout"; exit 2 }
}

# Try to attach the Domino console. 550 means the server is not running.
send "Gconsole $fqdn\r"
set need_start 0
expect {
    -re "210-" {}
    -re "550-" { set need_start 1 }
    timeout    { puts stderr "Gconsole timeout"; exit 2 }
}

if {$need_start} {
    puts stderr "Domino not running — starting via Gstart $fqdn..."
    send "Gstart $fqdn\r"
    set timeout 180
    expect {
        -re "(?i)started" {}
        -re "550-"        { puts stderr "Gstart rejected"; exit 2 }
        timeout           { puts stderr "Gstart timeout"; exit 2 }
    }
    # Give Domino time to bring up RunJava / Genesis.
    sleep 30
    set timeout 30
    send "Gconsole $fqdn\r"
    expect {
        -re "210-" {}
        timeout    { puts stderr "Gconsole failed after Gstart"; exit 2 }
    }
}

# Drain residual handshake / scrollback so the next read is clean.
set timeout 1
while {1} {
    set got 0
    expect {
        -re ".+" { set got 1; exp_continue }
        timeout {}
    }
    if {!$got} { break }
}

# Poll `tell genesis info` until Genesis answers (or 90s elapse).
set deadline [expr {[clock seconds] + 90}]
set version ""
while {[clock seconds] < $deadline} {
    send "Ctell genesis info\r"
    set timeout 5
    set buf ""
    while {1} {
        set got 0
        expect {
            -re ".+" { set got 1; append buf $expect_out(buffer); exp_continue }
            timeout {}
        }
        if {!$got} { break }
    }
    if {[regexp -nocase {version[\s:]+(\S+)} $buf -> v]} {
        set version $v
        break
    }
    sleep 5
}

if {$version eq ""} {
    puts stderr "Genesis did not respond with a version within 90s"
    exit 1
}

puts "VERSION=$version"
catch { close }
catch { wait }
exit 0
EOEXPECT
)

EXPECT_SCRIPT="${EXPECT_SCRIPT//FQDN_PLACEHOLDER/$FQDN}"

TMPF=$(mktemp -t cgv.XXXXXX.exp)
trap 'rm -f "$TMPF"' EXIT
printf '%s\n' "$EXPECT_SCRIPT" > "$TMPF"

output=$(expect -f "$TMPF") || exit $?

ver=$(printf '%s\n' "$output" | grep -m1 '^VERSION=' | cut -d= -f2-)
[[ -n "$ver" ]] || fail "Could not extract version from JeDI response"
echo "$ver"
