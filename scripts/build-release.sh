#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# build-release.sh — sign + notarize a distributable DeviceTerm.app.
#
# Pipeline (docs/BUILDING.md → "Code signing & release"):
#   1. swift build --configuration release
#   2. assemble DeviceTerm.app (scripts/make-app-bundle.sh release)
#   3. codesign nested code INNER → OUTER, hardened runtime + timestamp
#   4. codesign --verify --deep --strict the assembled app
#   5. zip (ditto) and submit to notarytool --wait
#   6. staple the ticket onto the .app
#   7. (optional, --dmg) build + notarize + staple a DMG
#   8. Gatekeeper assessment (spctl) on the stapled app
#
# GhosttyKit is statically linked (otool -L shows only system frameworks
# + the Swift runtime), so there is no embedded framework to re-sign —
# only the helpers, the embedded daemon login-item bundle, and the outer
# app carry Mach-O code.
#
# Credentials (real run only; never required for --dry-run):
#   CODESIGN_IDENTITY   Developer ID Application identity, e.g.
#                       "Developer ID Application: Your Name (TEAMID)".
#   Notarization, either:
#     NOTARY_PROFILE    a `notarytool store-credentials` keychain profile
#   or the triplet:
#     APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#
# Usage:
#   scripts/build-release.sh            sign + notarize + staple the app
#   scripts/build-release.sh --dmg      also produce a notarized DMG
#   scripts/build-release.sh --dry-run  offline preflight only (no creds,
#                                        no build, no network); used by
#                                        `make verify`.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="release"
BUILD="$ROOT/.build/$CONFIG"
APP="$BUILD/DeviceTerm.app"
OUT="$ROOT/release"
ENTITLEMENTS="$ROOT/Sources/App/Resources/deviceterm.entitlements"
PLIST="$ROOT/Sources/App/Resources/Info.plist"

# Machine-local signing/notarization config (git-ignored). Sourced
# automatically so `make release` needs no manual exports. See
# .env.release.example for the template.
if [ -f "$ROOT/.env.release" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env.release"
    set +a
fi

DRY_RUN=0
MAKE_DMG=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --dmg)     MAKE_DMG=1 ;;
        *) echo "build-release: unknown flag '$arg'" >&2; exit 2 ;;
    esac
done

note() { printf '  → %s\n' "$1"; }
die()  { printf 'build-release: %s\n' "$1" >&2; exit 1; }

version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" \
        2>/dev/null || echo "0.0.0"
}

# ── Dry run: offline preflight only ───────────────────────────────────
# Hermetic — no credentials, no build, no network — so `make verify`
# stays green on any machine. Confirms the tools the real run needs are
# present and the signing inputs exist.
if [ "$DRY_RUN" -eq 1 ]; then
    for tool in codesign ditto hdiutil xcrun; do
        command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
    done
    xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found (Xcode)"
    xcrun --find stapler    >/dev/null 2>&1 || die "stapler not found (Xcode)"
    [ -f "$ENTITLEMENTS" ] || die "entitlements not found: $ENTITLEMENTS"
    [ -f "$PLIST" ]        || die "Info.plist not found: $PLIST"
    [ -x "$ROOT/scripts/make-app-bundle.sh" ] || die "make-app-bundle.sh missing"
    # The GPL requires the license to accompany the binary it covers, so
    # it's a required release input, not a nicety. Caught here rather than
    # after signing and notarizing an artifact that can't be shipped.
    [ -f "$ROOT/LICENSE" ] || die "LICENSE not found: $ROOT/LICENSE"
    echo "build-release: dry-run OK (preflight passed; v$(version))"
    exit 0
fi

# ── Real run: require signing identity + notary credentials ───────────
: "${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY to your Developer ID Application identity}"

# Resolve notarytool auth: a stored keychain profile wins; otherwise the
# Apple ID triplet. Build the argument array once.
NOTARY_ARGS=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] \
        && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
                 --password "$APPLE_APP_PASSWORD")
else
    die "set NOTARY_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD"
fi

security find-identity -v -p codesigning 2>/dev/null \
    | grep -qF "$CODESIGN_IDENTITY" \
    || die "signing identity not in keychain: $CODESIGN_IDENTITY
  (a 'Developer ID Application' cert is required — an 'Apple Development'
   cert cannot notarize. Create one at developer.apple.com → Certificates.)"

# Refuse to ship the placeholder Sparkle public key — an app built with it
# can't verify any update, so a "successful" release would be dead on
# arrival. Set the real EdDSA public key (see docs/RELEASING.md) first.
ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || echo '')"
case "$ED_KEY" in
    ''|REPLACE_WITH_*)
        die "SUPublicEDKey in $PLIST is still the placeholder.
  Generate the Sparkle EdDSA key and set the public key before releasing
  (see docs/RELEASING.md)." ;;
esac

VERSION="$(version)"
echo "build-release: deviceterm v$VERSION → $OUT"

# The bundle stamps HEAD into Info.plist as DTSourceCommit, and
# THIRD_PARTY_NOTICES.md tells recipients that commit is the corresponding
# source — it is also step 1 of the LGPL relink route for libintl. Releasing
# over uncommitted edits would ship binaries whose source is published
# nowhere, so this is a hard stop rather than a warning.
if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then
    echo "build-release: error: uncommitted changes in $ROOT" >&2
    git -C "$ROOT" status --short >&2
    echo "  Commit or stash them: a release must be reproducible from" >&2
    echo "  the commit its About window reports." >&2
    exit 1
fi

# 1–2. Clean release build + bundle.
note "swift build --configuration release"
swift build --configuration release >/dev/null
note "assembling $APP"
"$ROOT/scripts/make-app-bundle.sh" "$CONFIG" >/dev/null

DAEMON_APP="$APP/Contents/Library/LoginItems/deviceterm-daemon.app"
[ -d "$DAEMON_APP" ] || die "embedded daemon bundle missing: $DAEMON_APP"

# Sign one Mach-O / bundle with hardened runtime + secure timestamp.
sign() {
    codesign --force --options runtime --timestamp \
        --sign "$CODESIGN_IDENTITY" "$@"
}

# 3. Sign INNER → OUTER. Nested code must be signed before its container,
# or the container's seal won't cover it.
#
# The libghostty resource bundle (themes/terminfo/shell-integration) is
# deliberately NOT signed here: it is data-only (no Info.plist, no
# Mach-O), so codesign rejects it as a bundle, and it needs no nested
# signature; the outer app signature seals Contents/Resources.
note "signing nested code (inner → outer)"
# Short-lived helpers symlinked into each session's bin/.
for helper in deviceterm-cli deviceterm-shim deviceterm-probe; do
    [ -e "$APP/Contents/Helpers/$helper" ] && sign "$APP/Contents/Helpers/$helper"
done
# Sparkle framework internals (make-app-bundle.sh embedded it). Sparkle
# ships pre-signed; re-sign with our Developer ID + hardened runtime +
# timestamp for notarization. Deepest first: XPC services, updater tools,
# then the framework bundle.
SPARKLE_V="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SPARKLE_V" ]; then
    note "signing Sparkle.framework internals"
    for xpc in "$SPARKLE_V/XPCServices"/*.xpc; do
        [ -e "$xpc" ] && sign "$xpc"
    done
    [ -e "$SPARKLE_V/Autoupdate" ] && sign "$SPARKLE_V/Autoupdate"
    [ -e "$SPARKLE_V/Updater.app" ] && sign "$SPARKLE_V/Updater.app"
    sign "$APP/Contents/Frameworks/Sparkle.framework"
fi
# Embedded daemon: its executable first, then its bundle.
sign "$DAEMON_APP/Contents/MacOS/deviceterm-daemon"
sign "$DAEMON_APP"
# Outer app — entitlements (no-sandbox) ride here; hardened runtime is
# added by `sign`. This seals everything above.
note "signing DeviceTerm.app (entitlements + hardened runtime)"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$CODESIGN_IDENTITY" "$APP"

# 4. Verify the signature is internally consistent and picks up nesting.
note "codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP"

# 5. Zip + notarize. notarytool needs a zip/dmg/pkg, not a bare .app.
mkdir -p "$OUT"
ZIP="$OUT/deviceterm-$VERSION.zip"
note "zipping → $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
note "submitting to notarytool (waits for Apple)"
xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait

# 6. Staple the ticket onto the .app, then re-zip the stapled bundle so
# the distributed archive carries the ticket (the submitted zip does not).
note "stapling ticket onto DeviceTerm.app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 8. Gatekeeper assessment — what a fresh machine sees.
note "Gatekeeper assessment (spctl)"
spctl --assess --type exec --verbose=4 "$APP" || \
    echo "  (spctl warning — review above)"

# Copy the stapled app next to the zip for convenience.
rm -rf "$OUT/DeviceTerm.app"
ditto "$APP" "$OUT/DeviceTerm.app"

# 7. Optional DMG: build from the stapled app, then notarize + staple it
# so the DMG download path is also ticketed.
if [ "$MAKE_DMG" -eq 1 ]; then
    DMG="$OUT/deviceterm-$VERSION.dmg"
    note "building DMG → $DMG"
    rm -f "$DMG"
    # Stage the app beside the license so both land at the volume root.
    # GPL section 6 wants the license to accompany the binary, and the
    # DMG is the download path most users take.
    DMG_STAGE="$OUT/dmg-stage"
    rm -rf "$DMG_STAGE"
    mkdir -p "$DMG_STAGE"
    ditto "$OUT/DeviceTerm.app" "$DMG_STAGE/DeviceTerm.app"
    cp "$ROOT/LICENSE" "$DMG_STAGE/LICENSE"
    hdiutil create -volname "DeviceTerm" -srcfolder "$DMG_STAGE" \
        -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$DMG_STAGE"
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
    note "notarizing DMG"
    xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

echo "build-release: done — artifacts in $OUT"
ls -1 "$OUT"
