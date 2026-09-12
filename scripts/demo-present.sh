#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/demo-present.sh — a presenter-style demo driver for recording
# deviceterm screencasts.
#
# You run this INSIDE an Automation tab (Shell → Open Automation Tab,
# ⌘⇧T) in a SECOND, off-camera window. It reads a demo file (one shell
# command per line) and, each time you press a key, "types" the next
# command into the recorded terminal pane one character at a time using
# `deviceterm pane send-input --type-delay`. The animated typing
# appears in the recorded window; this driver window (and its keypresses)
# stay out of frame.
#
# The driver waits for the recorded viewport to settle before offering
# each step. Output from a still-running command interleaves visually
# with the echoed input, which makes the recording look garbled.
# See --settle.
#
# Why a shell script and not a built-in verb: deviceterm provides the
# primitive (`pane send-input --type-delay`); the demo *content* and the
# presenter loop are workflow, which is the shell's job. Edit the demo
# file, not this script, to change what the screencast shows.
#
# Usage:
#   scripts/demo-present.sh <demo-file> [--target <pane-ref>] [--speed <ms>]
#                           [--settle <ms>] [--no-settle]
#
#   <demo-file>       One command per line. Blank lines and lines starting
#                     with `#` are skipped (use `#` for presenter notes).
#   --target <ref>    The recorded terminal pane (shortId / name / UUID). If
#                     omitted, the driver finds the sole other visible tab and
#                     uses its sole terminal pane. Pass --target when either
#                     choice is ambiguous.
#   --speed <ms>      Per-character typing delay in milliseconds
#                     (default: 45). 0 = instant.
#   --settle <ms>     How long the recorded pane viewport must hold still
#                     before a step is offered (default: 1500, maximum wait
#                     60000). Raise it if a demo runs commands that pause
#                     between output.
#   --no-settle       Don't wait; offer every step immediately.
#
# See docs/DEMO.md for the full recording workflow.

set -euo pipefail

die() { printf 'demo-present: %s\n' "$*" >&2; exit 1; }

DEMO_FILE=""
TARGET=""
SPEED=45
SETTLE=1500
# Upper bound on a single settle wait, so a demo that leaves something
# genuinely long-running can't wedge the driver.
SETTLE_TIMEOUT=60000
POLL_MS=300
POLL_SECONDS=0.3

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="${2:-}"; shift 2 ;;
        --speed)  SPEED="${2:-}";  shift 2 ;;
        --settle) SETTLE="${2:-}"; shift 2 ;;
        --no-settle) SETTLE=0; shift ;;
        -h|--help)
            sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --) shift; break ;;
        -*) die "unknown option: $1" ;;
        *)  [ -z "$DEMO_FILE" ] && DEMO_FILE="$1" || die "unexpected argument: $1"; shift ;;
    esac
done
[ -n "$DEMO_FILE" ] || die \
    "usage: demo-present.sh <demo-file> [--target <ref>] [--speed <ms>] [--settle <ms>] [--no-settle]"
[ -f "$DEMO_FILE" ] || die "demo file not found: $DEMO_FILE"
case "$SPEED" in ''|*[!0-9]*) die "--speed expects a non-negative integer (milliseconds)";; esac
case "$SETTLE" in ''|*[!0-9]*) die "--settle expects a non-negative integer (milliseconds)";; esac

command -v deviceterm >/dev/null 2>&1 \
    || die "the 'deviceterm' CLI isn't on PATH — run this inside a deviceterm tab"

# Auto-target: pick the sole terminal pane in the sole other visible tab.
# Public workspace reads come from the GUI projection, so tab discovery and
# pane discovery are intentionally separate rather than inferred from daemon
# sessions.
if [ -z "$TARGET" ]; then
    command -v jq >/dev/null 2>&1 \
        || die "auto-target needs 'jq'; install it or pass --target <ref>"
    other_tab="$(deviceterm tab list --all --json \
        | jq -r '[.[] | select(.current | not)]
                 | if length == 1 then .[0].id else empty end')"
    [ -n "$other_tab" ] \
        || die "couldn't auto-pick a tab; leave one other visible tab, or pass --target <pane-ref>"
    TARGET="$(deviceterm tab show "$other_tab" --json \
        | jq -r '[.panes[] | select(.kind == "terminal")]
                 | if length == 1
                   then (.[0].shortId // .[0].id)
                   else empty end')"
    [ -n "$TARGET" ] \
        || die "couldn't auto-pick a terminal; leave one terminal in the recorded tab, or pass --target"
fi

# Block until the recorded pane's viewport stays unchanged for the settle
# interval. Unchanged pixels prove quiescence, not that a command
# finished, which is what the known limit below is about.
#
# `pane capture-text` prints the rendered viewport, so comparing successive
# captures is a prompt-agnostic readiness check: no assumption about
# what the recorded shell's prompt looks like. The screen must hold
# still for the whole --settle window, not merely across one poll, so a
# command that pauses between output lines (`simctl bootstatus` prints
# roughly once a second) doesn't read as finished mid-run.
#
# Known limit: a foreground command that runs long and prints *nothing*
# is indistinguishable from an idle prompt. Nothing on the wire exposes
# the pane's foreground process, so quiescence is the available signal.
settle_wait() {
    [ "$SETTLE" -gt 0 ] || return 0
    local needed=$(( (SETTLE + POLL_MS - 1) / POLL_MS ))
    [ "$needed" -lt 1 ] && needed=1
    local waited=0 stable=0 announced=0 last="" now
    while :; do
        # A failed capture must not read as a still screen. Swallowing
        # the error would make every failure compare equal to the last
        # one, satisfy the stability counter, and quietly turn the gate
        # into a no-op that still looked like it was protecting you.
        if ! now="$(deviceterm pane capture-text "$TARGET" 2>/dev/null)"; then
            printf '\ndemo-present: pane capture failed — settle gate off for the rest of this run\n' >&2
            SETTLE=0
            return 0
        fi
        if [ "$waited" -gt 0 ] && [ "$now" = "$last" ]; then
            stable=$((stable + 1))
            [ "$stable" -ge "$needed" ] && break
        else
            stable=0
        fi
        last="$now"
        if [ "$waited" -ge "$SETTLE_TIMEOUT" ]; then
            printf '\ndemo-present: pane still busy after %sms — offering the step anyway\n' \
                "$SETTLE_TIMEOUT" >&2
            break
        fi
        # Only mention waiting once the pane viewport is visibly busy, so the
        # common case (already idle) stays quiet.
        if [ "$announced" -eq 0 ] && [ "$waited" -ge "$SETTLE" ]; then
            printf '\ndemo-present: waiting for the recorded pane viewport to settle…'
            announced=1
        fi
        sleep "$POLL_SECONDS"
        waited=$((waited + POLL_MS))
    done
    [ "$announced" -eq 1 ] && printf ' ready.\n'
    return 0
}

printf 'demo-present: target=%s speed=%sms settle=%sms — press any key to type each step (Ctrl-C to stop)\n' \
    "$TARGET" "$SPEED" "$SETTLE"

step=0
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    step=$((step + 1))
    # Gate BEFORE offering the step, not after sending it: when the
    # prompt appears the recorded pane viewport is already idle, so a keypress
    # types immediately instead of landing on a busy shell.
    settle_wait
    printf '\n[%d] → %s' "$step" "$line"
    # Wait for a presenter keypress (one char, no echo, no Enter needed).
    #
    # The loop redirects stdin from the demo file, so read presenter keys
    # from /dev/tty rather than consuming the next file character. A bare
    # read here eats the first character of any command that directly
    # follows another; blank lines and `#` notes between steps hide it,
    # since the stolen character comes from a line the loop skips.
    IFS= read -rsn1 _key < /dev/tty
    printf '\n'
    # Type the command + a real newline (Enter) into the recorded pane.
    # `--` passes the command verbatim so embedded --flags aren't eaten;
    # the trailing newline runs it. printf builds one argv with a real LF
    # so there's no backslash-escape ambiguity in the command text.
    printf -v payload '%s\n' "$line"
    deviceterm pane send-input "$TARGET" --type-delay "$SPEED" -- "$payload"
done < "$DEMO_FILE"

printf '\ndemo-present: done (%d steps).\n' "$step"
