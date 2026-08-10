#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/test-device-live.sh — the deliberate live physical-device track.
#
# DeviceLiveTests drives the daemon's RealDeviceBackend against a real,
# connected iPhone/iPad: bring the CoreDevice tunnel up ourselves (borrowing
# devicectl via TunnelKeepalive) → enumerate → resolve the backend → frames
# flow → HID discovery under the media-stream auth gate → touch. Non-hermetic,
# so kept out of `make verify` / `make test` (both --skip it). Run after
# changing RealDeviceBackend / the physical device path.
#
# Prerequisites (the device-interaction protocol):
#   • an iPhone/iPad plugged in, UNLOCKED, and trusted;
#   • Device Hub / Xcode's "Devices and Simulators" window CLOSED — deviceterm
#     holds the tunnel up on its own now; a Device-Hub "view screen" would
#     also consume the single video stream the mirror needs. (The tunnel may
#     be down at start — the track brings it up.)
#
# This track NEVER reboots or shuts down the device. It fails loudly when no
# device is connected — it does not silently no-op.

set -euo pipefail
cd "$(dirname "$0")/.."

# Precheck: is a physical device connected? `devicectl list devices` reaches
# the device over usbmux/lockdown with NO tunnel up, so this works with Device
# Hub closed — exactly the state the track runs in. Fail fast if none is
# listed; the track's first test is the authoritative check.
tmp_json="$(mktemp -t deviceterm-devicectl-precheck)"
trap 'rm -f "${tmp_json}"' EXIT
xcrun devicectl list devices --json-output "${tmp_json}" >/dev/null 2>&1 || true
if ! grep -q '"reality"[[:space:]]*:[[:space:]]*"physical"' "${tmp_json}" 2>/dev/null; then
    echo "test-device-live: no connected physical device found." >&2
    echo "  Connect an iPhone/iPad, UNLOCK and trust it (Device Hub can stay closed)." >&2
    echo "  (Verify with 'xcrun devicectl list devices'.)" >&2
    exit 1
fi

echo "test-device-live: connected device present — running the track."
echo "test-device-live: deviceterm brings the tunnel up itself (Device Hub not required)."
echo "test-device-live: this never reboots or shuts down your device."

# Run serially (the tests share one device + tunnel) and capture the status
# so the result is surfaced clearly.
set +e
swift test --no-parallel --filter DeviceLiveTests
status=$?
set -e

if [ "${status}" -eq 0 ]; then
    echo "test-device-live: ok"
else
    echo "test-device-live: FAILED (exit ${status})" >&2
fi
exit "${status}"
