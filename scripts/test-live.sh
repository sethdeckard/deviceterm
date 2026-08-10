#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/test-live.sh — the deliberate live-simulator test track.
#
# The CoreSimulatorLiveTests target needs a *booted* sim and drives real
# HID / AX / display I/O (plus the daemon's booted-owned contract). Those
# tests are non-hermetic and slow, so they're kept out of `make verify` /
# `make test`. Run this after changing CoreSimulatorBridge or other
# private-API code.
#
# It owns a clean slate:
#   1. shut down ALL simulators — including any you're running (by design,
#      so the live tests aren't poisoned by arbitrary sim state),
#   2. boot an iPhone on the newest installed runtime (the one you
#      actually develop against, so it's warm and boots fast) and wait —
#      with a timeout — until it's fully up,
#   3. run the live track,
#   4. shut that device back down — always, via a trap, so a bootstatus
#      timeout, a Ctrl-C, or a test failure can't strand the device.
#
# WARNING: step 1 stops your running simulators.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "test-live: shutting down all simulators (clean slate)…"
xcrun simctl shutdown all 2>/dev/null || true

# Pick a device by family preference: iPhone, then iPad, then anything.
# `simctl list` groups by runtime oldest-first, so the *last* match is on
# the newest installed runtime — the one you develop against, which is
# warm and boots quickly (head -1 would grab the oldest, often-cold one).
# iPhone is the canonical pane target, so it's preferred; iPad is next.
# The final "any" still reaches a watchOS/tvOS sim when that's all that's
# installed (deviceterm supports those too) — but it won't be picked over an
# available iPad just because simctl lists watches last.
uuid_re='[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}'
available=$(xcrun simctl list devices available)
# `|| true`: with `set -euo pipefail`, a no-match grep makes the pipeline
# exit 1, which would abort the (unguarded) first assignment before the
# fallbacks run. Treat "no match" as an empty result, not a failure.
pick_device() { printf '%s\n' "${available}" | grep -i "$1" | grep -ioE "${uuid_re}" | tail -1 || true; }
# DEVICETERM_LIVE_DEVICE_FAMILY=watch flips the preference to a watchOS sim
# (for the Digital Crown / watch-pane work); default is unchanged. Watch
# first-boot is slow — raise DEVICETERM_LIVE_BOOT_TIMEOUT if it times out.
if [ "${DEVICETERM_LIVE_DEVICE_FAMILY:-}" = "watch" ]; then
    udid=$(pick_device 'Apple Watch')
    if [ -z "${udid}" ]; then
        echo "test-live: DEVICETERM_LIVE_DEVICE_FAMILY=watch, but no watch sim is available" >&2
        exit 1
    fi
else
    udid=$(pick_device 'iPhone')
    [ -n "${udid}" ] || udid=$(pick_device 'iPad')
    [ -n "${udid}" ] || udid=$(printf '%s\n' "${available}" | grep -ioE "${uuid_re}" | tail -1 || true)
fi
if [ -z "${udid}" ]; then
    echo "test-live: no available simulator to boot — install a runtime first" >&2
    exit 1
fi

# Tell the runner which family-gated tests will run vs. skip, and how to
# flip to the other track — otherwise the watchOS Digital Crown tests skip
# silently on the default run and nobody knows they exist.
if [ "${DEVICETERM_LIVE_DEVICE_FAMILY:-}" = "watch" ]; then
    echo "test-live: watch track — running the watchOS Digital Crown tests."
else
    echo "test-live: default track — watchOS Digital Crown tests will skip;" \
         "run 'DEVICETERM_LIVE_DEVICE_FAMILY=watch make test-live' to run them."
fi

cleanup() {
    echo "test-live: shutting down ${udid}…"
    xcrun simctl shutdown "${udid}" 2>/dev/null || true
}

echo "test-live: booting ${udid}…"
xcrun simctl boot "${udid}"
# Arrange cleanup the instant the boot succeeds, on every exit path
# (normal, error under `set -e`, or Ctrl-C / kill) — otherwise a
# bootstatus timeout or a test failure would strand the device.
trap cleanup EXIT INT TERM

# Wait until the device is fully booted (AX server up) so the tree-walk
# tests don't race a half-booted SpringBoard — but bound it with a
# watchdog so a wedged/cold boot fails the track instead of hanging.
echo "test-live: waiting for ${udid} to finish booting…"
timeout_secs="${DEVICETERM_LIVE_BOOT_TIMEOUT:-240}"
xcrun simctl bootstatus "${udid}" &
bs_pid=$!
( sleep "${timeout_secs}"; kill "${bs_pid}" 2>/dev/null ) &
wd_pid=$!
boot_ok=0
if wait "${bs_pid}"; then boot_ok=1; fi
kill "${wd_pid}" 2>/dev/null || true
wait "${wd_pid}" 2>/dev/null || true
if [ "${boot_ok}" -ne 1 ]; then
    echo "test-live: ${udid} did not finish booting within ${timeout_secs}s" >&2
    echo "           (a cold runtime's first boot is slow; retry, or raise" >&2
    echo "            DEVICETERM_LIVE_BOOT_TIMEOUT)" >&2
    exit 1
fi

# Run the track serially (the tests share one sim) and capture the status
# so the trap still shuts the device down, then surface the result.
set +e
swift test --no-parallel --filter CoreSimulatorLiveTests
status=$?
set -e

if [ "${status}" -eq 0 ]; then
    echo "test-live: ok"
else
    echo "test-live: FAILED (exit ${status})" >&2
fi
exit "${status}"
