#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# make-app-bundle.sh — assemble .build/<config>/DeviceTerm.app from the
# SwiftPM build products.
#
# Modes:
#   - default (no extra args): production-style bundle. Auto-detects
#     CODESIGN_IDENTITY from .env.release. When present, signs
#     Developer-ID-style (hardened runtime + entitlements, but no
#     secure timestamp; scripts/build-release.sh adds that, and the
#     DO_SIGN case below says why). When absent, leaves the bundle
#     unsigned with a visible note: the GUI still starts, but
#     SMAppService cannot demand-launch the unsigned helper. Ad-hoc
#     is not the fallback because libghostty and Gatekeeper interact
#     badly with a bare ad-hoc host bundle. This is the path the GUI
#     smoke gate (`make verify`'s gui-smoke check) takes on machines
#     without release credentials.
#   - --ephemeral: builds into a per-run temp dir and ad-hoc signs,
#     needing no credentials. The only mode that ad-hoc signs, and
#     the only one that writes outside .build.
#
# Production release builds go through scripts/build-release.sh,
# which requires CODESIGN_IDENTITY + the full notarize/staple
# pipeline.
#
# Layout (docs/ARCHITECTURE.md "Process layout"):
#   DeviceTerm.app/Contents/
#     Info.plist
#     MacOS/deviceterm
#     Library/LaunchAgents/com.deviceterm.daemon.plist
#     Library/LoginItems/deviceterm-daemon.app/Contents/{Info.plist,MacOS/deviceterm-daemon}
#     Helpers/{deviceterm-cli,deviceterm-shim,deviceterm-probe}
#     Resources/<GhosttyKitResources bundle> + ghostty/ (fallback tree)
#
# Idempotent: rebuilds the .app from scratch each run.

set -eu

CONFIG="${1:-debug}"
MODE="default"
case "${2:-}" in
    --ephemeral) MODE="ephemeral" ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/$CONFIG"

if [ "$MODE" = "ephemeral" ]; then
    # Per-run temp dir; never collides with a developer's normal
    # output bundle. Teardown is the caller's responsibility.
    OUTPUT_DIR="$(mktemp -d -t deviceterm-ephemeral-bundle.XXXXXX)"
    APP="$OUTPUT_DIR/DeviceTerm.app"
else
    APP="$BUILD/DeviceTerm.app"
fi

SRC_PLIST="$ROOT/Sources/App/Resources/Info.plist"
SRC_LAUNCH_AGENT="$ROOT/Sources/App/Resources/LaunchAgents/com.deviceterm.daemon.plist"
SRC_ENTITLEMENTS="$ROOT/Sources/App/Resources/deviceterm.entitlements"

if [ ! -x "$BUILD/deviceterm" ]; then
    echo "make-app-bundle: $BUILD/deviceterm not found — run 'swift build' first" >&2
    exit 1
fi

# Resolve signing identity. Default mode prefers Developer-ID via
# .env.release; with no credentials it leaves the bundle unsigned (with
# a note) so the GUI smoke gate runs on machines without paid Apple
# Developer Program memberships. It stays unsigned rather than ad-hoc
# because libghostty and Gatekeeper interact badly with a bare ad-hoc
# host bundle. Ephemeral mode always ad-hoc signs.
SIGN_IDENTITY=""
SIGN_KIND="adhoc"
if [ "$MODE" = "default" ]; then
    if [ -f "$ROOT/.env.release" ]; then
        # shellcheck disable=SC1090
        . "$ROOT/.env.release"
    fi
    if [ -n "${CODESIGN_IDENTITY:-}" ]; then
        SIGN_IDENTITY="$CODESIGN_IDENTITY"
        SIGN_KIND="developer-id"
    else
        SIGN_KIND="unsigned"
        echo "make-app-bundle: note: CODESIGN_IDENTITY not set; the bundle" >&2
        echo "  will be unsigned and the embedded daemon helper cannot be" >&2
        echo "  demand-launched. For a launchable dev bundle, configure" >&2
        echo "  .env.release per .env.release.example." >&2
    fi
else
    SIGN_IDENTITY="-"
    SIGN_KIND="adhoc"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Library/LaunchAgents"
mkdir -p "$APP/Contents/Library/LoginItems"
mkdir -p "$APP/Contents/Helpers"

cp "$SRC_PLIST" "$APP/Contents/Info.plist"
cp "$BUILD/deviceterm" "$APP/Contents/MacOS/deviceterm"

# Bake the source commit into the bundled Info.plist (not the source
# plist) so the About window can show it. Best-effort: a shallow/exportless
# tree or absent git yields "unknown", which the About view treats as a dev
# build and hides the row.
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
/usr/libexec/PlistBuddy -c "Add :DTSourceCommit string $COMMIT" \
    "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :DTSourceCommit $COMMIT" \
        "$APP/Contents/Info.plist"

# App icon (CFBundleIconFile=AppIcon → Contents/Resources/AppIcon.icns).
cp "$ROOT/Sources/App/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# deviceterm's own license. The GPL requires the license text to accompany
# the binary it covers, so it travels inside the bundle rather than only in
# the repo. Hard failure, not a warning: a bundle without it can't be
# shipped, and every path that signs or notarizes one starts here.
if [ ! -f "$ROOT/LICENSE" ]; then
    echo "make-app-bundle: error: LICENSE not found at $ROOT/LICENSE" >&2
    exit 1
fi
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

# Third-party license attributions — surfaced via Help > Third-Party
# Notices (Bundle.main lookup). Bundling it also satisfies the SIL OFL
# 1.1 requirement that the font license travel with the embedded fonts.
if [ -f "$ROOT/THIRD_PARTY_NOTICES.md" ]; then
    cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
else
    echo "make-app-bundle: warning: THIRD_PARTY_NOTICES.md not found — skipping" >&2
fi

# Full texts of the long licenses THIRD_PARTY_NOTICES.md points at.
# Apache-2.0 section 4(a) and LGPL-2.1 section 6 both require a copy of
# the license to travel with the binary, not just a URL, so these are a
# hard failure like LICENSE rather than a warning like the notices file.
if [ ! -d "$ROOT/licenses" ]; then
    echo "make-app-bundle: error: licenses/ not found at $ROOT/licenses" >&2
    exit 1
fi
rm -rf "$APP/Contents/Resources/licenses"
cp -R "$ROOT/licenses" "$APP/Contents/Resources/licenses"

# Sparkle framework (auto-update). SwiftPM builds Sparkle.framework next to
# the executable; embed it under Contents/Frameworks and teach the
# executable to find it there (its build-dir @loader_path rpath doesn't
# apply once relocated into the bundle). Copied before signing so the
# inside-out codesign pass below seals it.
SPARKLE_FW="$BUILD/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP/Contents/MacOS/deviceterm" 2>/dev/null || true
else
    echo "make-app-bundle: warning: Sparkle.framework not found at $SPARKLE_FW" >&2
fi

# LaunchAgent plist — the launchd registration source that
# `SMAppService.agent(plistName:)` reads. Must match the constant
# in `Sources/DaemonProtocol/MachServiceName.swift` exactly; the
# LaunchAgentPlistTests guard catches drift.
cp "$SRC_LAUNCH_AGENT" "$APP/Contents/Library/LaunchAgents/com.deviceterm.daemon.plist"

# Embedded daemon helper bundle (LSUIElement, no Dock icon).
DAEMON_APP="$APP/Contents/Library/LoginItems/deviceterm-daemon.app"
mkdir -p "$DAEMON_APP/Contents/MacOS"
cp "$BUILD/deviceterm-daemon" "$DAEMON_APP/Contents/MacOS/deviceterm-daemon"
cat > "$DAEMON_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>deviceterm-daemon</string>
    <key>CFBundleIdentifier</key><string>com.deviceterm.daemon</string>
    <key>CFBundleExecutable</key><string>deviceterm-daemon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Seth Deckard</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Helper executables.
for helper in deviceterm-cli deviceterm-shim deviceterm-probe; do
    if [ -x "$BUILD/$helper" ]; then
        cp "$BUILD/$helper" "$APP/Contents/Helpers/$helper"
    else
        echo "make-app-bundle: warning: $helper not built — skipping" >&2
    fi
done

# libghostty runtime resources. Primary mechanism: copy the SwiftPM
# resource bundle next to Bundle.main's resources so the bridge's
# `GhosttyKitResources.directoryURL` (Bundle.module) resolves inside
# the .app. Defense-in-depth: also drop the raw tree at
# Contents/Resources/ghostty for TerminalPaneVC's bundled fallback.
RES_BUNDLE=""
for b in "$BUILD"/*GhosttyKitResources*.bundle; do
    [ -d "$b" ] && RES_BUNDLE="$b" && break
done
if [ -z "$RES_BUNDLE" ]; then
    echo "make-app-bundle: error: GhosttyKitResources bundle not found in $BUILD" >&2
    echo "  (the terminal pane would have no terminfo/shell-integration)" >&2
    exit 1
fi
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
GHOSTTY_TREE=""
for d in "$RES_BUNDLE"/Resources "$RES_BUNDLE"/Contents/Resources/Resources; do
    [ -d "$d/terminfo" ] && GHOSTTY_TREE="$d" && break
done
if [ -z "$GHOSTTY_TREE" ]; then
    echo "make-app-bundle: error: terminfo tree not found under $RES_BUNDLE" >&2
    exit 1
fi
rm -rf "$APP/Contents/Resources/ghostty"
cp -R "$GHOSTTY_TREE" "$APP/Contents/Resources/ghostty"

# Sign the bundle when we have credentials. The ephemeral path always
# ad-hoc signs, so its output can be codesign --verify'd. Default mode
# with no credentials remains unsigned so development and the GUI smoke
# gate work without paid Developer Program membership (libghostty and
# macOS Gatekeeper interact badly when the host bundle is bare ad-hoc
# signed). When the user has Developer ID configured, the full
# inside-out sign + hardened-runtime path runs.
SIGN_FLAGS=""
ENTITLEMENT_FLAG=""
DO_SIGN="no"
case "$MODE:$SIGN_KIND" in
    default:developer-id)
        # No --timestamp here. Timestamping reaches Apple's TSA and can
        # block for minutes when the server is slow; the dev gui-smoke
        # gate calls this script ~6× per run (helpers + daemon Mach-O +
        # daemon .app + outer .app) so one slow TSA round-trip
        # compounds. Notarization is the only thing that requires a
        # secure timestamp, and scripts/build-release.sh does that for
        # real releases.
        SIGN_FLAGS="--options runtime --force"
        ENTITLEMENT_FLAG="--entitlements $SRC_ENTITLEMENTS"
        DO_SIGN="yes"
        ;;
    ephemeral:adhoc)
        SIGN_FLAGS="--force"
        DO_SIGN="yes"
        ;;
esac

if [ "$DO_SIGN" = "yes" ]; then
    # Inside-out: helpers, Sparkle framework internals, then inner helper
    # .app, then outer .app.
    for helper in deviceterm-cli deviceterm-shim deviceterm-probe; do
        if [ -x "$APP/Contents/Helpers/$helper" ]; then
            codesign $SIGN_FLAGS --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/$helper"
        fi
    done
    # Sparkle ships pre-signed by the Sparkle project; re-sign its nested
    # code with our identity (and hardened runtime in developer-id mode)
    # so the outer seal is consistent. Deepest first: XPC services, the
    # updater tools, then the framework bundle.
    SPARKLE_V="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    if [ -d "$SPARKLE_V" ]; then
        for xpc in "$SPARKLE_V/XPCServices"/*.xpc; do
            [ -e "$xpc" ] && codesign $SIGN_FLAGS --sign "$SIGN_IDENTITY" "$xpc"
        done
        [ -e "$SPARKLE_V/Autoupdate" ] && \
            codesign $SIGN_FLAGS --sign "$SIGN_IDENTITY" "$SPARKLE_V/Autoupdate"
        [ -e "$SPARKLE_V/Updater.app" ] && \
            codesign $SIGN_FLAGS --sign "$SIGN_IDENTITY" "$SPARKLE_V/Updater.app"
        codesign $SIGN_FLAGS --sign "$SIGN_IDENTITY" \
            "$APP/Contents/Frameworks/Sparkle.framework"
    fi
    codesign $SIGN_FLAGS --sign "$SIGN_IDENTITY" "$DAEMON_APP/Contents/MacOS/deviceterm-daemon"
    codesign $SIGN_FLAGS --sign "$SIGN_IDENTITY" "$DAEMON_APP"
    if [ -n "$ENTITLEMENT_FLAG" ]; then
        codesign $SIGN_FLAGS $ENTITLEMENT_FLAG --sign "$SIGN_IDENTITY" "$APP"
    else
        codesign $SIGN_FLAGS --sign "$SIGN_IDENTITY" "$APP"
    fi
fi

echo "make-app-bundle: built $APP (mode=$MODE, sign=$SIGN_KIND)"
if [ "$MODE" = "ephemeral" ]; then
    echo "$OUTPUT_DIR"
fi
