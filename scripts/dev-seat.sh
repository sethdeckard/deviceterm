#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/dev-seat.sh: the dev seat, one worktree the user has blessed
# with sole use of the machine-shared dev resources.
#
# Every other guard is first-come: the instance guard and the track locks
# belong to whoever gets there first, and let go when it stops. The seat
# is a reservation instead. The user gives it to one checkout, and while
# it stands, only that checkout may launch the app (`make run`) or take
# the sim, device, or uitest lock. Every other checkout refuses with a
# BUSY block naming the seat, whether or not the seat's app is running.
# With no seat, nothing changes.
#
# Blessing, moving, and ending the seat each ask for confirmation on
# /dev/tty and refuse when there is no terminal to ask on. There is no
# flag to skip the question. That makes a change need a controlling
# terminal, not a person: anything that supplies a pseudo-terminal can
# answer it, as verify.sh's self-test does. Leaving the seat to the user
# is a convention agents follow, not an identity check.
#
# The seat is a directory in /tmp, beside the locks, so it outlasts every
# relaunch and ends at reboot. Nothing reclaims it: only `unbless`, or
# blessing another checkout, ends it.
#
# Subcommands:
#   bless             give the seat to this checkout (asks first)
#   unbless           end the seat, whichever checkout holds it (asks first)
#   status            print the seat's holder, or "free" (exit 1)
#   check <resource>  exit 0 if this checkout may use <resource>; otherwise
#                     print BUSY and exit 75
#
# `--seat-dir <dir>`, before the subcommand, moves the seat directory, for
# verify.sh's self-test. It is a flag rather than an environment variable
# because the real gates never pass it: the Makefile and the track scripts
# omit it, and exclusive-lock.sh forwards it only when its own caller
# supplied it, which only the self-test does. A variable would reach those
# gates from a caller's shell and let that caller step around the seat.

set -euo pipefail
export LC_ALL=C

cd "$(dirname "$0")/.."
. scripts/lib/busy.sh

seat="/tmp/deviceterm.$(id -u).seat"
if [ "${1:-}" = "--seat-dir" ]; then
    [ -n "${2:-}" ] || { echo "usage: dev-seat.sh [--seat-dir <dir>] <subcommand>" >&2; exit 64; }
    seat="$2"
    shift 2
fi
root="$(pwd -P)"

usage() {
    echo "usage: dev-seat.sh [--seat-dir <dir>] bless|unbless|status" >&2
    echo "       dev-seat.sh [--seat-dir <dir>] check <resource>" >&2
    exit 64
}

# Holder file: checkout root, then when it was blessed.
read_seat() {
    s_root=$(sed -n 1p "$seat/holder" 2>/dev/null || true)
    s_when=$(sed -n 2p "$seat/holder" 2>/dev/null || true)
}

# Ask on the terminal itself, never stdin, so a pipe can't answer.
confirm() {
    if ! { exec 3<>/dev/tty; } 2>/dev/null; then
        echo "dev-seat: there is no terminal to confirm on, so nothing changed." >&2
        echo "dev-seat: the seat is the user's to give. Run this yourself, in a terminal." >&2
        exit 1
    fi
    printf '%s [y/N] ' "$1" >&3
    answer=""
    read -r answer <&3 || true
    exec 3<&-
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "dev-seat: nothing changed." >&2; exit 1 ;;
    esac
}

# A change to the seat runs under exclusive-lock.sh's `mutate` lock, rooted
# in the seat directory so the self-test's seat brings its own. Taken only
# after the user has answered, so a question left open never blocks another
# terminal. That script already owns reclaiming a lock whose owner died,
# serialized and owner-checked, so a second caller can't clear a lock a
# third has just taken. A concurrent change refuses with BUSY.
lock_seat() {
    mkdir -p "$seat"
    scripts/exclusive-lock.sh --lock-root "$seat" acquire mutate $$
    trap 'scripts/exclusive-lock.sh --lock-root "$seat" release mutate $$' EXIT
}

# Change the seat only if it still reads as it did when the user was asked:
# while the question was open, another terminal may have moved it, and the
# answer was about the seat as it stood then.
require_unchanged() {
    seen_root="$s_root"
    seen_when="$s_when"
    lock_seat
    read_seat
    if [ "$s_root" != "$seen_root" ] || [ "$s_when" != "$seen_when" ]; then
        echo "dev-seat: the seat changed while you were answering (now: ${s_root:-free}); nothing changed." >&2
        exit 1
    fi
}

bless() {
    read_seat
    if [ "$s_root" = "$root" ]; then
        echo "dev-seat: this checkout already holds the seat (blessed $s_when)."
        exit 0
    fi
    if [ -n "$s_root" ]; then
        confirm "Move the dev seat from $s_root to $root?"
    else
        confirm "Give the dev seat to $root?"
    fi
    require_unchanged
    # Written whole, then renamed into place, so a reader never sees half.
    printf '%s\n%s\n' "$root" "$(date)" > "$seat/holder.tmp.$$"
    mv -f "$seat/holder.tmp.$$" "$seat/holder"
    echo "dev-seat: $root holds the seat."
}

unbless() {
    read_seat
    if [ -z "$s_root" ]; then
        echo "dev-seat: no checkout holds the seat."
        exit 0
    fi
    confirm "End the dev seat held by $s_root?"
    require_unchanged
    rm -f "$seat/holder"
    echo "dev-seat: the seat is free."
}

status_cmd() {
    read_seat
    if [ -z "$s_root" ]; then
        echo "free"
        exit 1
    fi
    if [ "$s_root" = "$root" ]; then
        echo "held: root=$s_root blessed=$s_when (this checkout)"
    else
        echo "held: root=$s_root blessed=$s_when"
    fi
}

check() {
    read_seat
    if [ -z "$s_root" ] || [ "$s_root" = "$root" ]; then
        exit 0
    fi
    dt_busy_seat "$1, which the dev seat reserves" "$s_root" "$s_when"
    exit 75
}

case "${1:-}" in
    bless)   bless ;;
    unbless) unbless ;;
    status)  status_cmd ;;
    check)   [ -n "${2:-}" ] || usage; check "$2" ;;
    *)       usage ;;
esac
