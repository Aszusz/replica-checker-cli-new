#!/usr/bin/env bash
# domino.sh — Public verbs for driving a local Domino server.
#
# Source this file (do not execute). Each verb is one-shot: it opens its own
# telnet to the local JeDI listener (port 1910), does its work, and closes.
# No coproc, no shared state, no globals.
#
# Public API:
#
#   run_domino_command --cmd <cmd> --until <regex> [--match <regex>] [--verbose]
#       Runs a Domino console command (the "C-forwarded" tell flavor) and
#       prints output until <regex> matches.
#
#       If --match has no capture group, every line matching it is emitted.
#       If --match has a capture group, only the captured substring is emitted.
#       Without --match, every line is emitted.
#
#       Probes state via Gstatus. If Domino is STOPPED it issues Gstart and
#       waits for RUNNING before sending the tell. Caller never sees state.
#
#   stop_domino [--timeout N] [--verbose]
#       Probes state. If already STOPPED, no-op. Otherwise sends Gstop and
#       polls Gstatus until state is STOPPED (default timeout: 120s).
#
#   start_domino [--timeout N] [--verbose]
#       Probes state. If already RUNNING, no-op. Otherwise sends Gstart and
#       polls Gstatus until state is RUNNING (default timeout: 180s).
#
# Connection defaults: port 1910, user admin, pass pass.
# Override per call with --port / --user / --pass.
#
# --verbose echoes the JeDI handshake and ">>> <command>" markers to stderr,
# matching the trace the original monolithic check-genesis-version.sh produced.

command -v expect >/dev/null 2>&1 || {
    echo "ERROR: domino.sh requires 'expect' (apt install expect)" >&2
    return 1 2>/dev/null || exit 1
}

##############################################################################
# run_domino_command
##############################################################################

run_domino_command() {
    local cmd="" until_re="" match_re="" verbose=""
    local port=1910 user=admin pass=pass

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cmd)     cmd="$2";      shift 2 ;;
            --until)   until_re="$2"; shift 2 ;;
            --match)   match_re="$2"; shift 2 ;;
            --port)    port="$2";     shift 2 ;;
            --user)    user="$2";     shift 2 ;;
            --pass)    pass="$2";     shift 2 ;;
            --verbose) verbose=1;     shift ;;
            *) echo "ERROR: run_domino_command: unknown arg: $1" >&2; return 1 ;;
        esac
    done

    [[ -n "$cmd"      ]] || { echo "ERROR: run_domino_command: --cmd required"   >&2; return 1; }
    [[ -n "$until_re" ]] || { echo "ERROR: run_domino_command: --until required" >&2; return 1; }

    JEDI_PORT="$port" JEDI_USER="$user" JEDI_PASS="$pass" JEDI_VERBOSE="$verbose" \
    JEDI_CMD="$cmd" JEDI_UNTIL="$until_re" JEDI_MATCH="$match_re" \
    _domino_expect run_command
}

##############################################################################
# stop_domino
##############################################################################

stop_domino() {
    local timeout=120 verbose=""
    local port=1910 user=admin pass=pass

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) timeout="$2"; shift 2 ;;
            --port)    port="$2";    shift 2 ;;
            --user)    user="$2";    shift 2 ;;
            --pass)    pass="$2";    shift 2 ;;
            --verbose) verbose=1;    shift ;;
            *) echo "ERROR: stop_domino: unknown arg: $1" >&2; return 1 ;;
        esac
    done

    JEDI_PORT="$port" JEDI_USER="$user" JEDI_PASS="$pass" JEDI_VERBOSE="$verbose" \
    JEDI_TIMEOUT="$timeout" \
    _domino_expect transition_to STOPPED Gstop
}

##############################################################################
# start_domino
##############################################################################

start_domino() {
    local timeout=180 verbose=""
    local port=1910 user=admin pass=pass

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) timeout="$2"; shift 2 ;;
            --port)    port="$2";    shift 2 ;;
            --user)    user="$2";    shift 2 ;;
            --pass)    pass="$2";    shift 2 ;;
            --verbose) verbose=1;    shift ;;
            *) echo "ERROR: start_domino: unknown arg: $1" >&2; return 1 ;;
        esac
    done

    JEDI_PORT="$port" JEDI_USER="$user" JEDI_PASS="$pass" JEDI_VERBOSE="$verbose" \
    JEDI_TIMEOUT="$timeout" \
    _domino_expect transition_to RUNNING Gstart
}

##############################################################################
# Internal: dispatch into the expect script.
# $1 = mode; remaining args are mode-specific.
##############################################################################

_domino_expect() {
    local mode="$1"; shift
    JEDI_MODE="$mode" JEDI_TARGET_STATE="${1:-}" JEDI_TRANSITION_CMD="${2:-}" \
    expect /dev/fd/3 3<<'EXPECT_EOF'
log_user 0
set timeout 10

set port    $env(JEDI_PORT)
set user    $env(JEDI_USER)
set pass    $env(JEDI_PASS)
set VERBOSE $env(JEDI_VERBOSE)
set mode    $env(JEDI_MODE)

# Mode-specific inputs (some may be empty depending on mode).
set tell_cmd        [expr {[info exists env(JEDI_CMD)]              ? $env(JEDI_CMD)              : ""}]
set until_re        [expr {[info exists env(JEDI_UNTIL)]            ? $env(JEDI_UNTIL)            : ""}]
set match_re        [expr {[info exists env(JEDI_MATCH)]            ? $env(JEDI_MATCH)            : ""}]
set target_state    $env(JEDI_TARGET_STATE)
set transition_cmd  $env(JEDI_TRANSITION_CMD)
set timeout_seconds [expr {[info exists env(JEDI_TIMEOUT)]          ? $env(JEDI_TIMEOUT)          : "120"}]

proc log_v {msg} {
    global VERBOSE
    if {$VERBOSE ne ""} {
        puts stderr $msg
        flush stderr
    }
}

# Send Gstatus, capture and return [list uid state]. Logs the line in verbose mode.
proc gstatus {} {
    log_v ">>> Gstatus"
    send "Gstatus\r"
    expect -re "Configured domino servers:"
    expect -re "(240- (\\S+): (\\S+)\[^\n]*)\n"
    set line  $expect_out(1,string)
    set uid   $expect_out(2,string)
    set state $expect_out(3,string)
    log_v $line
    return [list $uid $state]
}

# Poll Gstatus until state == target or deadline passes.
proc wait_for_state {target deadline} {
    while {1} {
        set info [gstatus]
        set state [lindex $info 1]
        if {$state eq $target} { return [lindex $info 0] }
        if {[clock seconds] >= $deadline} {
            send_user "ERROR: timed out waiting for state $target (current: $state)\n"
            exit 1
        }
        sleep 3
    }
}

# --- Connect + Glogin (common to every mode) ---
spawn telnet 0 $port
expect -re "(250-\[^\n]*)\n"
log_v $expect_out(1,string)

log_v ">>> Glogin $user $pass"
send "Glogin $user $pass\r"
expect -re "(204-\[^\n]*)\n"
log_v $expect_out(1,string)

# --- Probe state ---
set info  [gstatus]
set uid   [lindex $info 0]
set state [lindex $info 1]

# --- Dispatch ---
if {$mode eq "transition_to"} {
    set deadline [expr {[clock seconds] + $timeout_seconds}]

    if {$state eq $target_state} {
        log_v "Already $target_state. No-op."
    } else {
        log_v ">>> $transition_cmd $uid"
        send "$transition_cmd $uid\r"
        # Accept any coded response line; we verify the real outcome via polling.
        expect {
            -re "(\[0-9]+-\[^\n]*)\n" { log_v $expect_out(1,string) }
            timeout                    { log_v "(no immediate response to $transition_cmd)" }
        }
        wait_for_state $target_state $deadline
    }

    log_v ">>> Glogout"
    send "Glogout\r"
    expect -re "(251-\[^\n]*)\n"
    log_v $expect_out(1,string)
    exit 0
}

if {$mode eq "run_command"} {
    # Auto-start if needed.
    if {$state ne "RUNNING"} {
        set deadline [expr {[clock seconds] + 180}]
        log_v ">>> Gstart $uid (auto, state was $state)"
        send "Gstart $uid\r"
        expect {
            -re "(\[0-9]+-\[^\n]*)\n" { log_v $expect_out(1,string) }
            timeout                    { log_v "(no immediate response to Gstart)" }
        }
        set uid [wait_for_state RUNNING $deadline]
    }

    log_v ">>> Gconsole $uid"
    send "Gconsole $uid\r"
    expect -re "(210-\[^\n]*)\n"
    log_v $expect_out(1,string)

    log_v "(draining scrollback...)"
    set timeout 2
    expect {
        -re "(?s).+" { exp_continue }
        timeout {}
    }
    set timeout 30

    log_v ">>> C$tell_cmd"
    send "C$tell_cmd\r"
    set looping 1
    while {$looping} {
        expect {
            -re "(\[^\n]*)\n" {
                set line $expect_out(1,string)
                if {$match_re eq ""} {
                    send_user "$line\n"
                } else {
                    set sub1 ""
                    if {[regexp $match_re $line full sub1]} {
                        if {$sub1 ne ""} {
                            send_user "$sub1\n"
                        } else {
                            send_user "$full\n"
                        }
                    }
                }
                if {[regexp $until_re $line]} { set looping 0 }
            }
            timeout {
                send_user "ERROR: timeout waiting for /$until_re/\n"
                exit 1
            }
        }
    }

    log_v ">>> Glogout"
    send "Glogout\r"
    expect -re "(251-\[^\n]*)\n"
    log_v $expect_out(1,string)
    exit 0
}

send_user "ERROR: unknown mode '$mode'\n"
exit 1
EXPECT_EOF
}
