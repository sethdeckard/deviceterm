#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/exclusive-lock.sh: per-user, cross-checkout mutex for the
# exclusive test tracks.
#
# test-live, test-device-live, and test-uitest each drive a resource
# shared by this user's checkouts: the simulator fleet, the one physical
# device and its tunnel, the TCC-granted harness plus the singleton GUI.
# Two checkouts running the same track concurrently corrupt each other,
# so each track takes a named lock. Different tracks touch different
# hardware and stay independent.
#
# The lock is a directory. mkdir is the atomic primitive; macOS ships no
# flock(1). Use /tmp so HOME or TMPDIR overrides cannot split the
# cross-checkout lock namespace; the uid suffix separates users.
#
# Contention fails fast (BUSY block, exit 75); there is no wait mode.
# For a valid holder record, reclaiming needs positive evidence that the
# owner is gone. An empty holder file is retried once; a still-missing
# or malformed pid is treated as an interrupted acquisition and
# reclaimed. Evidence of a gone owner is:
#   - kill -0 reports ESRCH, or the recorded start time no longer
#     matches (the pid was reused), AND
#   - no process survives in the owner's process group. The recorded pid
#     is a track wrapper whose real work runs in a `swift test` child; a
#     SIGKILLed wrapper leaves that child driving the resource with no
#     trap to release the lock.
# Anything ambiguous, such as EPERM under a sandbox, counts as live, so
# blindness never steals a lock. Both arms ask the kernel through
# kill -0 rather than enumerating processes, since enumeration is what a
# sandbox denies. The group arm errs toward refusing: a track launched
# from a nested script shares that script's process group, so its lock
# stays unreclaimable while the parent lives, and a holder whose own
# group could not be determined at acquire time is never reclaimed
# automatically at all. The BUSY block for that case names the lock
# directory to remove by hand.
#
# Reclaiming runs under a second mkdir mutex, itself owner-stamped, so
# two contenders cannot reclaim at once and a stalled reclaimer cannot
# have its work undone by a peer that assumed it died.
#
# Subcommands:
#   acquire <track> <holder-pid>   take the lock or exit 75 with BUSY
#   release <track> <holder-pid>   drop the lock iff <holder-pid> owns it;
#                                  missing lock is a silent success so
#                                  traps stay idempotent
#   status  <track>                print the holder (exit 0) or "free"
#                                  (exit 1)

set -euo pipefail

# The ESRCH match and the process start-time comparison below both parse
# locale-sensitive strings (strerror text, ps date format). Pin the
# locale so two runs under different environments agree.
export LC_ALL=C

cd "$(dirname "$0")/.."
. scripts/lib/busy.sh

usage() {
    echo "usage: exclusive-lock.sh acquire|release <track> <holder-pid>" >&2
    echo "       exclusive-lock.sh status <track>" >&2
    exit 64
}

cmd="${1:-}"
track="${2:-}"
case "$track" in
    ''|*[!A-Za-z0-9._-]*) usage ;;
esac
lock="/tmp/deviceterm.$(id -u).${track}.lock"
recover="$lock.recover"
# A recovery mutex whose owner cannot be identified at all (killed
# between its mkdir and its holder write, a window of microseconds) has
# only its age to settle it.
recover_max_age=30

ps_lstart() {
    ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//' || true
}

# A process group, learned without enumerating where possible: ps first,
# then a leader probe. A process that leads its own group has a group id
# equal to its pid, so signaling that group proves it; no other group can
# carry a live process's pid as its id. Anything else is "unknown", which
# readers treat as unverifiable rather than empty.
ps_pgid() {
    pgid=$(ps -p "$1" -o pgid= 2>/dev/null | tr -d ' ' || true)
    if [ -n "$pgid" ]; then
        printf '%s\n' "$pgid"
    elif kill -0 -- -"$1" 2>/dev/null; then
        printf '%s\n' "$1"
    else
        printf 'unknown\n'
    fi
}

# Holder file: pid, start time, checkout root, track, process group.
read_holder_at() {
    h_pid=$(sed -n 1p "$1/holder" 2>/dev/null || true)
    h_lstart=$(sed -n 2p "$1/holder" 2>/dev/null || true)
    h_root=$(sed -n 3p "$1/holder" 2>/dev/null || true)
    h_pgid=$(sed -n 5p "$1/holder" 2>/dev/null || true)
}

read_holder() { read_holder_at "$lock"; }

write_holder_at() {
    {
        printf '%s\n' "$2"
        printf '%s\n' "$(ps_lstart "$2")"
        pwd -P
        printf '%s\n' "$track"
        printf '%s\n' "$(ps_pgid "$2")"
    } > "$1/holder"
}

write_holder() { write_holder_at "$lock" "$1"; }

# The holder file is written after mkdir succeeds, so a contender can
# glimpse an empty or missing file mid-write. During acquisition, retry
# an empty holder file once before treating it as stale.
retry_empty_holder() {
    if [ -z "${h_pid:-}" ]; then
        sleep 1
        read_holder
    fi
}

# kill -0 fails for a target that is gone (ESRCH) and for one this
# process may not signal (EPERM under a sandbox), and the two must not
# be confused: only ESRCH is evidence of absence. Match the errno text
# case-insensitively, since shells differ on how they capitalize it.
kill_says_gone() {
    case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
        *"no such process"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Positive evidence that a pid is gone. ps disagreeing (it still sees
# the pid) also wins.
holder_is_dead() {
    kill_err=$(kill -0 "$1" 2>&1) && return 1
    if kill_says_gone "$kill_err"; then
        [ -z "$(ps -p "$1" -o pid= 2>/dev/null)" ] || return 1
        return 0
    fi
    return 1
}

# Signaling a negative pid targets a process group, so this asks the
# kernel rather than enumerating processes: enumeration is what a
# sandbox denies, and an empty pgrep would then read as "no survivors"
# and hand out a lock that a live orphan is still using.
group_has_survivors() {
    # No group to check is not evidence of an empty one. Reclaiming here
    # would hand the resource to a second track while the first one's
    # orphaned child still drives it.
    case "${1:-}" in
        ''|unknown) return 0 ;;
    esac
    kill_err=$(kill -0 -- -"$1" 2>&1) && return 0
    if kill_says_gone "$kill_err"; then
        return 1
    fi
    return 0
}

# live | stale, from the holder fields read by read_holder_at.
holder_state() {
    # A missing or malformed pid identifies no live holder; reclaiming
    # is what keeps a crash between mkdir and the holder write from
    # wedging the track permanently.
    case "${h_pid:-}" in
        ''|*[!0-9]*) echo stale; return ;;
    esac
    if ! holder_is_dead "$h_pid"; then
        cur_lstart=$(ps_lstart "$h_pid")
        if [ -z "$cur_lstart" ] || [ -z "${h_lstart:-}" ] || [ "$cur_lstart" = "${h_lstart:-}" ]; then
            echo live
            return
        fi
        # The pid belongs to an unrelated process now; the wrapper is
        # gone, but its children may not be.
    fi
    if group_has_survivors "${h_pgid:-}"; then
        echo live
    else
        echo stale
    fi
}

busy_and_exit() {
    what="an exclusive test track holds this lock"
    recovery=""
    # An owner that is gone but whose process group cannot be checked
    # keeps the lock indefinitely, since its children may still be
    # driving the resource. Nothing will clear it, so hand the operator
    # the step out instead of leaving the refusal looking unbreakable.
    case "${h_pgid:-}" in
        ''|unknown)
            case "${h_pid:-}" in
                ''|*[!0-9]*) ;;
                *)
                    if holder_is_dead "$h_pid"; then
                        what="the lock owner is gone, and its process group cannot be checked here"
                        recovery="confirm no $track track is running in any checkout, then: rm -rf $lock"
                    fi
                    ;;
            esac
            ;;
    esac
    dt_busy "lock:$track" "$what" \
        "${h_pid:-unknown}" "${h_lstart:-unknown}" "${h_root:-$lock}" "$recovery"
    exit 75
}

# A recovery mutex with a valid holder record uses the lock's liveness
# checks; an invalid or missing record expires after recover_max_age.
# Age alone for a valid record would let one contender delete a live
# reclaimer's mutex, and the reclaimer would then remove whatever lock
# the contender had put in its place.
recovery_owner_gone() {
    read_holder_at "$recover"
    case "${h_pid:-}" in
        ''|*[!0-9]*)
            age=$(( $(date +%s) - $(stat -f %m "$recover" 2>/dev/null || echo 0) ))
            if [ "$age" -ge "$recover_max_age" ]; then return 0; fi
            return 1
            ;;
    esac
    [ "$(holder_state)" = stale ]
}

clear_orphan_recovery_mutex() {
    if [ -d "$recover" ]; then
        if recovery_owner_gone; then
            rm -rf "$recover"
        fi
    fi
    return 0
}

acquire() {
    holder_pid="$1"
    if mkdir "$lock" 2>/dev/null; then
        write_holder "$holder_pid"
        exit 0
    fi
    read_holder
    retry_empty_holder
    if [ "$(holder_state)" = live ]; then
        busy_and_exit
    fi
    # Reclaim under the recovery mutex, so the canonical lock cannot be
    # reclaimed by another contender between the fresh staleness check
    # below and the removal: a contender that cannot enter recovery also
    # cannot mkdir the canonical path while the stale dir still sits
    # there. Re-read the holder inside the mutex rather than trusting
    # what was read outside it.
    clear_orphan_recovery_mutex
    if mkdir "$recover" 2>/dev/null; then
        write_holder_at "$recover" "$holder_pid"
        read_holder
        retry_empty_holder
        if [ "$(holder_state)" != live ]; then
            rm -rf "$lock"
            # A fresh acquirer can win the path here; then this mkdir
            # fails and this process refuses below. Nobody double-holds.
            if mkdir "$lock" 2>/dev/null; then
                write_holder "$holder_pid"
                rm -rf "$recover"
                exit 0
            fi
        fi
        rm -rf "$recover"
    fi
    # Another contender is mid-recovery, or won the reclaimed lock. A
    # holder write delayed past the retry interval also lands here.
    sleep 1
    read_holder
    busy_and_exit
}

release() {
    holder_pid="$1"
    [ -d "$lock" ] || exit 0
    read_holder
    if [ "${h_pid:-}" = "$holder_pid" ]; then
        rm -rf "$lock"
    else
        echo "exclusive-lock: not releasing $track — held by pid ${h_pid:-unknown}, not $holder_pid" >&2
    fi
    exit 0
}

status_cmd() {
    if [ -d "$lock" ]; then
        read_holder
        echo "held: track=$track pid=${h_pid:-unknown} started=${h_lstart:-unknown} root=${h_root:-unknown}"
        exit 0
    fi
    echo "free"
    exit 1
}

case "$cmd" in
    acquire) [ -n "${3:-}" ] || usage; acquire "$3" ;;
    release) [ -n "${3:-}" ] || usage; release "$3" ;;
    status)  status_cmd ;;
    *)       usage ;;
esac
