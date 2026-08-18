#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/instance-guard.sh — worktree-scoped app/daemon process guard.
#
# The app and daemon are machine singletons (one bundle id, one launchd
# label, one mach service) but several checkouts build them, and a `pkill`
# by bundle-relative path fragment cannot tell them apart. This guard
# classifies every running deviceterm app/daemon process by its
# executable's physical path: under THIS checkout's .build it is "mine",
# anywhere else (another worktree, /Applications) it is "foreign".
# `make run` / `make kill-daemon` act only on "mine" and refuse with a
# BUSY block when a foreign instance holds the singleton — there is no
# force flag; the owner quits it from its own checkout.
#
# Sandboxed shells can be denied pgrep's process enumeration, so an empty
# pgrep means "cannot see / nothing there" and the guard proceeds. It
# never claims BUSY without evidence; the BUSY paths only fire on a
# positively identified foreign process.
#
# Subcommands:
#   status          print "pid  mine|foreign  exe" for every visible instance
#   refuse-foreign  exit 75 with a BUSY block if any foreign instance runs
#   kill-own        SIGTERM this checkout's pids only (daemon: wait + SIGKILL
#                   escalation); never /Applications, never another worktree
#   list-mine       print this checkout's pids, one per line
#   ensure-clear    refuse-foreign, then kill-own (the `make run` pre-flight)
#   resolve-exe PID print a pid's absolute executable path, which answers
#                   "which checkout is this daemon from?" for a launchd-
#                   spawned helper, whose own `comm` is bundle-relative

set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/lib/busy.sh

ROOT_PHYS="$(pwd -P)"

# Bundle-relative patterns match the app and daemon wherever their
# bundles live. The bracketed first letter prevents pgrep's own argv
# from matching; classify_all filters other argument-only matches by
# executable basename.
APP_PATTERN='[D]eviceTerm.app/Contents/MacOS/deviceterm'
DAEMON_PATTERN='[L]oginItems/deviceterm-daemon.app/Contents/MacOS/deviceterm-daemon'

# pid → absolute executable path, read from the process's mapped program
# text. Used when `comm` is relative, which path arithmetic cannot resolve
# without guessing a cwd. lsof reports the mapping itself, so the answer is
# absolute however the process was started.
#
# Takes the first `txt` entry, which is the program text; the rest are
# dylibs and resources. Should a lead entry ever not be the executable,
# `classify_all` rejects it on basename and the process goes unclassified,
# which is the same no-identification outcome as reading nothing at all.
# Empty when lsof is missing or denied, for the same reason.
exe_abs_via_lsof() {
    lsof -a -p "$1" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true
}

# pid → physical executable path; empty output if the pid died between
# enumeration and inspection. `ps -o comm=` is the kernel-recorded
# executable path on macOS (not argv, which processes can rewrite). The
# running binary's path may contain the `.build/arm64-apple-macosx/debug`
# form while this checkout compares as `.build/debug`, so physicalize the
# directory before comparing.
exe_phys_for() {
    local pid=$1 exe dir phys
    exe=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    [ -n "$exe" ] || return 0
    # comm is the literal execve path and is RELATIVE when the process was
    # launched by a relative path, which is how launchd starts the daemon:
    # the LaunchAgent's `BundleProgram` is bundle-relative, so every
    # demand-launched helper arrives here relative. Resolving that against
    # this script's own cwd would misattribute another checkout's process,
    # so read the mapped executable instead. No positive identification →
    # no classification (the blind-pgrep rule again).
    case "$exe" in
        /*) ;;
        *)
            exe=$(exe_abs_via_lsof "$pid")
            [ -n "$exe" ] || return 0
            ;;
    esac
    dir=$(dirname "$exe")
    phys=$(cd "$dir" 2>/dev/null && pwd -P || true)
    printf '%s/%s\n' "${phys:-$dir}" "$(basename "$exe")"
}

# Emit "pid<TAB>mine|foreign<TAB>exe_phys" per visible app/daemon process.
classify_all() {
    local pid exe_phys kind
    for pid in $(pgrep -f "$APP_PATTERN" 2>/dev/null || true) \
               $(pgrep -f "$DAEMON_PATTERN" 2>/dev/null || true); do
        exe_phys=$(exe_phys_for "$pid")
        [ -n "$exe_phys" ] || continue
        # pgrep -f matches argv anywhere, so a debugger or editor whose
        # arguments mention the bundle path also matches; only processes
        # whose executable IS a deviceterm binary get classified.
        case "$(basename "$exe_phys")" in
            deviceterm|deviceterm-daemon) ;;
            *) continue ;;
        esac
        case "$exe_phys" in
            "$ROOT_PHYS"/.build/*) kind=mine ;;
            *)                     kind=foreign ;;
        esac
        printf '%s\t%s\t%s\n' "$pid" "$kind" "$exe_phys"
    done
}

# The path a human resolves a foreign holder by: the owning checkout root
# when the executable lives under a .build, else the outermost .app bundle
# (covers /Applications/DeviceTerm.app and its embedded daemon).
holder_for() {
    case "$1" in
        */.build/*)   printf '%s\n' "${1%%/.build/*}" ;;
        */Contents/*) printf '%s\n' "${1%%/Contents/*}" ;;
        *)            printf '%s\n' "$1" ;;
    esac
}

refuse_foreign() {
    local pid kind exe_phys lstart
    while IFS=$'\t' read -r pid kind exe_phys; do
        [ "$kind" = foreign ] || continue
        lstart=$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//' || true)
        dt_busy app "the singleton deviceterm app/daemon is running from another checkout" \
            "$pid" "${lstart:-unknown}" "$(holder_for "$exe_phys")"
        exit 75
    done < <(classify_all)
}

kill_own() {
    local pid kind exe_phys own_app="" own_daemon="" remaining=""
    while IFS=$'\t' read -r pid kind exe_phys; do
        [ "$kind" = mine ] || continue
        case "$exe_phys" in
            */deviceterm-daemon) own_daemon="$own_daemon $pid" ;;
            *)                   own_app="$own_app $pid" ;;
        esac
    done < <(classify_all)
    for pid in $own_app $own_daemon; do
        kill "$pid" 2>/dev/null || true
    done
    if [ -n "$own_app$own_daemon" ]; then sleep 1; fi
    # The daemon handles SIGTERM cooperatively so it can log the exit and
    # unlink its socket, which makes the signal a request rather than a
    # guarantee. Wait briefly, then send SIGKILL if it is still running, so
    # a wedged main queue can't leave a stale daemon behind for `run` to
    # demand-launch against.
    for _ in 1 2 3 4; do
        remaining=""
        for pid in $own_daemon; do
            if kill -0 "$pid" 2>/dev/null; then remaining="$remaining $pid"; fi
        done
        [ -n "$remaining" ] || break
        sleep 0.5
    done
    if [ -n "$remaining" ]; then
        echo "daemon still running after SIGTERM; escalating to SIGKILL"
        for pid in $remaining; do
            kill -9 "$pid" 2>/dev/null || true
        done
    fi
    echo "stopped this checkout's deviceterm app + daemon (if running)"
}

list_mine() {
    local pid kind exe_phys
    while IFS=$'\t' read -r pid kind exe_phys; do
        [ "$kind" = mine ] || continue
        printf '%s\n' "$pid"
    done < <(classify_all)
}

status_cmd() {
    local out
    out=$(classify_all)
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
    else
        echo "no deviceterm app/daemon processes visible"
    fi
}

case "${1:-}" in
    status)         status_cmd ;;
    refuse-foreign) refuse_foreign ;;
    kill-own)       kill_own ;;
    list-mine)      list_mine ;;
    ensure-clear)   refuse_foreign; kill_own ;;
    resolve-exe)
        [ $# -eq 2 ] || { echo "usage: instance-guard.sh resolve-exe PID" >&2; exit 64; }
        exe_phys_for "$2"
        ;;
    *)
        echo "usage: instance-guard.sh" \
            "status|refuse-foreign|kill-own|list-mine|ensure-clear|resolve-exe PID" >&2
        exit 64
        ;;
esac
