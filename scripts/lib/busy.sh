#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/lib/busy.sh — the single BUSY emitter, sourced by
# instance-guard.sh, exclusive-lock.sh, and dev-seat.sh so the refusal
# format cannot drift between the guard tools.
#
# A BUSY refusal means something else holds a machine-shared resource
# right now: a process holding the singleton app/daemon or an
# exclusive-track lock (usually another checkout's, sometimes this
# checkout's own), or the dev seat the user reserved for another
# checkout. The caller prints this block and exits 75 (EX_TEMPFAIL: transient, retry
# later — distinguishable from a real failure). Line 1 is stable
# machine-parseable key=value; every line carries the prefix so a
# grep/tail slice still shows the rule.

# dt_busy <resource> <what> <pid> <lstart> <where> [recovery]
#   resource: app | lock:<track> (for example, lock:sim, lock:device,
#             or lock:uitest)
#   what:     one-line description of the contended thing
#   pid:      the holder's pid
#   lstart:   the holder's process start time (ps -o lstart=)
#   where:    owning checkout path, /Applications/..., or lock dir
#   recovery: manual step out, for the rare state that cannot clear
#             itself. Its presence drops the blanket "do not delete the
#             lock" clause, which would otherwise contradict it.
dt_busy() {
    {
        printf 'deviceterm-make: BUSY: resource=%s pid=%s holder=%s\n' "$1" "$3" "$5"
        printf 'deviceterm-make: BUSY:   what:  %s\n' "$2"
        printf 'deviceterm-make: BUSY:   who:   pid %s, started %s\n' "$3" "$4"
        printf 'deviceterm-make: BUSY:   where: %s\n' "$5"
        if [ -n "${6:-}" ]; then
            printf 'deviceterm-make: BUSY:   rule:  Do NOT kill any process and do NOT retry with force (no\n'
            printf 'deviceterm-make: BUSY:          force flag exists). Agents: stand down and report BUSY.\n'
            printf 'deviceterm-make: BUSY:   fix:   %s\n' "$6"
        else
            printf 'deviceterm-make: BUSY:   rule:  Another worktree'\''s work is in progress. Do NOT kill this\n'
            printf 'deviceterm-make: BUSY:          process, do NOT delete the lock, do NOT retry with force\n'
            printf 'deviceterm-make: BUSY:          (no force flag exists). Quit or finish it from its own\n'
            printf 'deviceterm-make: BUSY:          checkout, or wait. Agents: stand down and report BUSY.\n'
        fi
    } >&2
}

# dt_busy_seat <what> <root> <when>
#   The seat's refusal: the user reserved the resource for another
#   checkout (scripts/dev-seat.sh). Line 1 keeps dt_busy's key order;
#   a seat has no holder process, so pid is "-".
#   what: the refused resource; root: the seat's checkout; when: when
#   it was blessed.
dt_busy_seat() {
    {
        printf 'deviceterm-make: BUSY: resource=seat pid=- holder=%s\n' "$2"
        printf 'deviceterm-make: BUSY:   what:  %s\n' "$1"
        printf 'deviceterm-make: BUSY:   who:   the user, who blessed that checkout %s\n' "$3"
        printf 'deviceterm-make: BUSY:   where: %s\n' "$2"
        printf 'deviceterm-make: BUSY:   rule:  The user gave the dev seat to another worktree. Do NOT\n'
        printf 'deviceterm-make: BUSY:          unbless, re-bless, or delete the seat; only the user moves\n'
        printf 'deviceterm-make: BUSY:          it, from their own terminal. Agents: stand down and report BUSY.\n'
    } >&2
}
