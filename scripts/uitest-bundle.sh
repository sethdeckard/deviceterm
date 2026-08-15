#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# uitest-bundle.sh — assemble ~/Applications/DeviceTermUITestHarness.app
# from the deviceterm-uitest build product.
#
# Why a bundle at all: TCC attributes Screen Recording and Accessibility
# to the process that calls the API, resolved through its *responsible*
# process. A bare binary run from a shell attributes to the terminal app,
# so granting it would hand your terminal broad capture and input rights.
# A signed .app launched independently (via LaunchServices, see
# `make uitest-run`) carries its own identity, so the grants land here —
# and DeviceTerm.app itself never needs them.
#
# Why ~/Applications and not .build: the user has to grant this bundle two
# permissions in System Settings once. A path under the hidden .build tree
# is invisible in the Privacy "+" file picker and is wiped by `make clean`,
# forcing a re-grant. ~/Applications is a normal, visible app location that
# survives a clean, so — with a stable Developer-ID signature — the grant
# is genuinely one-time.
#
# Layout:
#   DeviceTermUITestHarness.app/Contents/
#     Info.plist              (LSUIElement — no Dock icon, no menu bar)
#     MacOS/deviceterm-uitest
#
# Signing: prefers CODESIGN_IDENTITY from .env.release (a stable identity
# keeps the TCC grant across rebuilds). Falls back to ad-hoc, which works
# but changes the code signature every rebuild — macOS may then quietly
# drop the grant. See docs/BUILDING.md.
#
# Dev/test-only. Never shipped: scripts/build-release.sh does not bundle
# this, and nothing in DeviceTerm.app depends on it.
#
# Idempotent: rebuilds the .app from scratch each run.

set -eu

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/$CONFIG"
BIN="$BUILD/deviceterm-uitest"
# Stable, visible install location (see header). Overridable for tests.
APP="${DEVICETERM_UITEST_APP:-$HOME/Applications/DeviceTermUITestHarness.app}"

if [ ! -x "$BIN" ]; then
    echo "uitest-bundle: $BIN not built — run 'make uitest' first" >&2
    exit 1
fi

# Replacing the shared bundle while another checkout's test-uitest track
# runs corrupts that run, so every harness writer takes the uitest lock.
# test-uitest.sh already holds it when it calls this script and says so
# via the env flag; locking again here would refuse against ourselves.
if [ -z "${DEVICETERM_UITEST_LOCK_HELD:-}" ]; then
    "$ROOT/scripts/exclusive-lock.sh" acquire uitest $$
    trap '"$ROOT/scripts/exclusive-lock.sh" release uitest $$' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi

mkdir -p "$(dirname "$APP")"

# Remove any stale copy at the historical .build location. Two bundles with
# the same id (com.deviceterm.uitest) confuse TCC — the Privacy toggle
# won't render for either, and a grant can attach to the wrong path. Skip
# the removal if the caller deliberately pointed the install there.
for stale in "$ROOT/.build/debug/DeviceTermUITestHarness.app" "$BUILD/DeviceTermUITestHarness.app"; do
    [ "$stale" = "$APP" ] || rm -rf "$stale"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/deviceterm-uitest"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DeviceTermUITestHarness</string>
    <key>CFBundleIdentifier</key><string>com.deviceterm.uitest</string>
    <key>CFBundleExecutable</key><string>deviceterm-uitest</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Resolve a signing identity. A stable Developer-ID identity keeps the
# TCC grant across rebuilds; ad-hoc re-signs with a new cdhash each time.
SIGN_IDENTITY="-"
SIGN_KIND="adhoc"
if [ -f "$ROOT/.env.release" ]; then
    # shellcheck disable=SC1090
    . "$ROOT/.env.release"
fi
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$CODESIGN_IDENTITY"
    SIGN_KIND="developer-id"
fi

codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/deviceterm-uitest"
codesign --force --sign "$SIGN_IDENTITY" "$APP"

echo "uitest-bundle: built $APP (sign=$SIGN_KIND)"
if [ "$SIGN_KIND" = "adhoc" ]; then
    echo "uitest-bundle: note: ad-hoc signed — the code signature changes on" >&2
    echo "  every rebuild, so macOS may drop a previously-granted Screen" >&2
    echo "  Recording / Accessibility permission. If capture starts failing" >&2
    echo "  after a rebuild, toggle the harness off and on in System Settings" >&2
    echo "  → Privacy & Security. Set CODESIGN_IDENTITY in .env.release for a" >&2
    echo "  stable identity that survives rebuilds." >&2
fi
