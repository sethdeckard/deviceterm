#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/gui-smoke.sh — pure-SwiftPM GUI smoke gate.
#
# Launches the bundled DeviceTerm.app with `--smoke`; the App's smoke
# handler (Sources/App/AppDelegate.swift::runSmokeCheck) self-verifies
# daemon spawn + libghostty load + first window/tab construction +
# a second daemon round-trip, then drives the Router-backed nav paths
# (newTab → closeTab, openWindow → selectWindow → closeWindow),
# asserting nav state at each stage, before exiting 0 on success / 1 on
# failure. By project tenet (no `.xcodeproj`, no XCTest UI) this script
# is the only GUI gate, and the same script also runs inside
# `make verify`, so regressions in dispatch / reconcile / multi-window
# bring-up surface in the default gate.
#
# What this gate does NOT exercise: the Detach/Shut-Down NSAlert prompt,
# the pane shutdown overlay (needs a real booted sim), the daemon's
# status item count, and the ⌘Q quit-with-sims sheet. Those need UI
# automation or live sims and live in Tests/Manual.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
BUNDLE=".build/${CONFIG}/DeviceTerm.app"
BINARY="${BUNDLE}/Contents/MacOS/deviceterm"

if [ ! -x "${BINARY}" ]; then
    echo "gui-smoke: bundle missing or not built at ${BUNDLE}" >&2
    echo "gui-smoke: run 'make bundle' first" >&2
    exit 1
fi

# Isolate: temp HOME so smoke doesn't write to the user's
# ~/Library/Caches/deviceterm/sessions/, and a temp daemon socket so we
# don't connect to (or accidentally co-opt) a daemon at the canonical
# location.
TMP="$(mktemp -d -t deviceterm-smoke)"
trap 'rm -rf "${TMP}"' EXIT

export HOME="${TMP}"
export DEVICETERM_DAEMON_SOCK="${TMP}/daemon.sock"

# Launch the binary directly (not via `open`) so argv passes through
# and stdout/stderr are captured here. The App's --smoke handler is
# responsible for exiting; the watcher below caps wall-clock as a
# safety net.
TIMEOUT_SECS=60
OUT_FILE="$(mktemp -t deviceterm-smoke-out)"
trap 'rm -rf "${TMP}" "${OUT_FILE}"' EXIT

"${BINARY}" --smoke >"${OUT_FILE}" 2>&1 &
APP_PID=$!

# Poll once per second so the watcher self-terminates the moment the
# app exits — `kill $WATCHER_PID` doesn't interrupt a bash subshell
# that's mid-`sleep`, so a single long sleep would leave the script
# blocked until timeout even when the app finished in 2s.
(
    i=0
    while [ "$i" -lt "${TIMEOUT_SECS}" ]; do
        sleep 1
        kill -0 "${APP_PID}" 2>/dev/null || exit 0
        i=$((i + 1))
    done
    echo "gui-smoke: app exceeded ${TIMEOUT_SECS}s — sending SIGTERM" >&2
    kill -TERM "${APP_PID}" 2>/dev/null || true
    sleep 1
    kill -KILL "${APP_PID}" 2>/dev/null || true
) &
WATCHER_PID=$!

status=0
wait "${APP_PID}" || status=$?
wait "${WATCHER_PID}" 2>/dev/null || true

out="$(cat "${OUT_FILE}")"

if [ "${status}" -ne 0 ]; then
    echo "gui-smoke: app exited with status ${status}" >&2
    echo "${out}" >&2
    exit 1
fi

if ! printf "%s\n" "${out}" | grep -q "smoke: ok"; then
    echo "gui-smoke: expected 'smoke: ok' in output" >&2
    echo "${out}" >&2
    exit 1
fi

echo "gui-smoke: ok"
