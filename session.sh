#!/usr/bin/env bash
# session.sh — Composable JeDI console session.
#
# Source this file (do not execute). Opens one telnet → Glogin → Gstatus →
# Gconsole attach to the local Domino JeDI listener and lets you fire many
# commands over the same session.
#
# Usage:
#   source ./session.sh
#   trap session_close EXIT
#   session_open
#   session_send_console --cmd "tell genesis info" --until "^Genesis: catalog"
#   session_send_console --cmd "tell SpawnTestDB info" --until "^SpawnTestDB: ready"
#   session_close
#
# API:
#   session_open [--port N] [--user U] [--pass P]
#       Defaults: --port 1910 --user admin --pass pass.
#       Aborts if the discovered server isn't RUNNING.
#
#   session_send_gateway --cmd <command> --expect <code>
#       For G* commands. Sends <command>, prints the matching "<code>- ..." line.
#
#   session_send_console --cmd <command> --until <regex> [--match <regex>]
#       For commands forwarded to the Domino console. Sends "C<command>" and
#       prints every output line until one matches --until. The caller picks
#       the terminator (e.g. "^Genesis: catalog" — the last line
#       `tell genesis info` emits). Optional --match filters which lines are
#       emitted (terminator still stops the loop even if it doesn't match).
#       Filter inside the helper to avoid bash pipelines, which close
#       the coproc fds in the subshell.
#
#   session_close
#       Sends Glogout and reaps the helper. Safe to call when no session open.
#
# All send_* functions print captured output on stdout, errors on stderr,
# and return non-zero on timeout.

command -v expect >/dev/null 2>&1 || {
    echo "ERROR: session.sh requires 'expect' (apt install expect)" >&2
    return 1 2>/dev/null || exit 1
}

_SESSION_IN=""
_SESSION_OUT=""
_SESSION_PID=""

# Sentinels framing helper → bash messages. Chosen to never collide with
# Domino console output.
_SESSION_READY='__JEDI_READY_a8f3__'
_SESSION_DONE='__JEDI_DONE_a8f3__'
_SESSION_CLOSED='__JEDI_CLOSED_a8f3__'
_SESSION_ERROR='__JEDI_ERROR_a8f3__'

session_open() {
    [[ -n "$_SESSION_PID" ]] && {
        echo "ERROR: session already open (pid $_SESSION_PID)" >&2
        return 1
    }

    local port=1910 user=admin pass=pass
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port) port="$2"; shift 2 ;;
            --user) user="$2"; shift 2 ;;
            --pass) pass="$2"; shift 2 ;;
            *) echo "ERROR: session_open: unknown arg: $1" >&2; return 1 ;;
        esac
    done

    coproc _JEDI { _session_run "$port" "$user" "$pass"; }
    _SESSION_PID=$_JEDI_PID
    _SESSION_OUT=${_JEDI[0]}
    _SESSION_IN=${_JEDI[1]}

    _session_drain_until "$_SESSION_READY" >/dev/null
}

session_close() {
    [[ -z "$_SESSION_PID" ]] && return 0
    # Brace-group the redirect so a "Bad file descriptor" from a stale fd
    # also lands in /dev/null (the shell-level redirect error happens before
    # printf's own 2>/dev/null would apply).
    { printf 'CLOSE\n' >&"$_SESSION_IN"; } 2>/dev/null || true
    _session_drain_until "$_SESSION_CLOSED" >/dev/null 2>&1 || true
    wait "$_SESSION_PID" 2>/dev/null || true
    _SESSION_PID="" _SESSION_IN="" _SESSION_OUT=""
}

session_send_gateway() {
    local cmd="" code=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cmd)    cmd="$2"; shift 2 ;;
            --expect) code="$2"; shift 2 ;;
            *) echo "ERROR: session_send_gateway: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ -n "$cmd"  ]] || { echo "ERROR: session_send_gateway: --cmd required" >&2; return 1; }
    [[ -n "$code" ]] || { echo "ERROR: session_send_gateway: --expect required" >&2; return 1; }

    printf 'GW %s\n%s\n' "$code" "$cmd" >&"$_SESSION_IN"
    _session_drain_until "$_SESSION_DONE"
}

session_send_console() {
    local cmd="" terminator="" match=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cmd)   cmd="$2"; shift 2 ;;
            --until) terminator="$2"; shift 2 ;;
            --match) match="$2"; shift 2 ;;
            *) echo "ERROR: session_send_console: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ -n "$cmd"        ]] || { echo "ERROR: session_send_console: --cmd required" >&2; return 1; }
    [[ -n "$terminator" ]] || { echo "ERROR: session_send_console: --until required" >&2; return 1; }

    printf 'CON %s\n%s\n%s\n' "$terminator" "$match" "$cmd" >&"$_SESSION_IN"
    _session_drain_until "$_SESSION_DONE"
}

# Read lines from the helper's stdout. Forward content lines to our stdout,
# stderr lines to our stderr, and return when the sentinel arrives.
_session_drain_until() {
    local sentinel="$1" line rc=0
    while IFS= read -r -u "$_SESSION_OUT" line; do
        if [[ "$line" == "$sentinel" ]]; then
            return "$rc"
        elif [[ "$line" == "$_SESSION_ERROR"* ]]; then
            printf '%s\n' "${line#"$_SESSION_ERROR" }" >&2
            rc=1
        else
            printf '%s\n' "$line"
        fi
    done
    return 1
}

# The expect helper. Reads control records on stdin, emits framed output on
# stdout. One control record = one or two lines:
#   "CLOSE\n"                       → Glogout
#   "GW <code>\n<command>\n"        → gateway command; reply line = "<code>- ..."
#   "CON <until>\n<match>\n<command>\n" → forwarded console; <match> may be empty
_session_run() {
    # Read the script from fd 3, NOT stdin. If we used `expect <<EOF` the
    # heredoc would become expect's stdin, and the `gets stdin` calls below
    # would read from the already-EOF heredoc instead of the coproc pipe —
    # the helper would exit immediately after emitting READY.
    JEDI_PORT="$1" JEDI_USER="$2" JEDI_PASS="$3" \
    JEDI_READY="$_SESSION_READY" JEDI_DONE="$_SESSION_DONE" \
    JEDI_CLOSED="$_SESSION_CLOSED" JEDI_ERROR="$_SESSION_ERROR" \
    expect /dev/fd/3 3<<'EXPECT_EOF'
log_user 0
set timeout 10

set port    $env(JEDI_PORT)
set user    $env(JEDI_USER)
set pass    $env(JEDI_PASS)
set READY   $env(JEDI_READY)
set DONE    $env(JEDI_DONE)
set CLOSED  $env(JEDI_CLOSED)
set ERROR   $env(JEDI_ERROR)

spawn telnet 0 $port
expect -re "250-\[^\n]*\n"

send "Glogin $user $pass\r"
expect -re "204-\[^\n]*\n"

send "Gstatus\r"
expect -re "Configured domino servers:"
expect -re "240- (\\S+): (\\S+)\[^\n]*\n"
set uid   $expect_out(1,string)
set state $expect_out(2,string)
if {$state ne "RUNNING"} {
    send_user "$ERROR server $uid is $state, not RUNNING\n"
    exit 1
}

send "Gconsole $uid\r"
expect -re "210-\[^\n]*\n"

# Gconsole replays recent console history on attach. Drain it once so it
# doesn't pollute the response to the first user command.
set timeout 2
expect {
    -re "(?s).+" { exp_continue }
    timeout {}
}
set timeout 30

send_user "$READY\n"

while {1} {
    if {[gets stdin kind] == -1} break

    if {$kind eq "CLOSE"} {
        send "Glogout\r"
        expect -re "251-\[^\n]*\n"
        send_user "$CLOSED\n"
        break
    }

    if {[regexp {^GW (.+)$} $kind -> code]} {
        if {[gets stdin cmd] == -1} break
        send "$cmd\r"
        expect {
            -re "($code-\[^\n]+)\n" { send_user "$expect_out(1,string)\n" }
            timeout                  { send_user "$ERROR timeout on $cmd\n" }
        }
        send_user "$DONE\n"
        continue
    }

    if {[regexp {^CON (.+)$} $kind -> term]} {
        if {[gets stdin match] == -1} break
        if {[gets stdin cmd]   == -1} break
        send "C$cmd\r"
        set looping 1
        while {$looping} {
            expect {
                -re "(\[^\n]*)\n" {
                    set line $expect_out(1,string)
                    if {$match eq "" || [regexp $match $line]} {
                        send_user "$line\n"
                    }
                    if {[regexp $term $line]} { set looping 0 }
                }
                timeout {
                    send_user "$ERROR timeout waiting for /$term/\n"
                    set looping 0
                }
            }
        }
        send_user "$DONE\n"
        continue
    }
}
EXPECT_EOF
}
