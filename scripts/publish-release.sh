#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# publish-release.sh: publish an already-built, notarized release.
#
# Runs *after* `make release` (scripts/build-release.sh --dmg) has produced
# a signed + notarized + stapled release/deviceterm-<version>.dmg. Kept
# separate from build-release.sh so that script's hermetic --dry-run (used
# by `make verify`) stays untouched and free of publish tooling.
#
# Steps:
#   1. Read VERSION from DeviceTermVersion.swift; compute the DMG's
#      sha256.
#   2. Generate the EdDSA-signed Sparkle appcast over the release DMG.
#   3. Create the GitHub release, uploading the DMG + appcast.xml so the
#      `releases/latest/download/appcast.xml` feed permalink serves it.
#   4. Render the Homebrew cask into the local tap checkout and commit +
#      push it. This step runs last so a failed release upload never
#      leaves the public cask pointing at a DMG that doesn't exist yet.
#
# Everything runs locally; there is no CI. Requires a public repo +
# `gh auth`.
#
# Environment:
#   DEVICETERM_TAP_DIR   Local checkout of sethdeckard/homebrew-tap
#                        (default: ../homebrew-tap). Cask lands at
#                        $DEVICETERM_TAP_DIR/Casks/deviceterm.rb.
#   SPARKLE_BIN_DIR      Dir holding Sparkle's `generate_appcast`
#                        (default: looks on PATH). The EdDSA private
#                        key is read from the login Keychain.
#
# Usage:
#   scripts/publish-release.sh              publish the current version
#   scripts/publish-release.sh --dry-run    print what would happen; no push,
#                                           no gh release, no network writes

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/release"
CASK_TEMPLATE="$ROOT/packaging/homebrew/deviceterm.rb"

if [ -f "$ROOT/.env.release" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env.release"
    set +a
fi

# After the sourcing above, so DEVICETERM_TAP_DIR set in .env.release works.
TAP_DIR="${DEVICETERM_TAP_DIR:-$ROOT/../homebrew-tap}"

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) echo "publish-release: unknown flag '$arg'" >&2; exit 2 ;;
    esac
done

note() { printf '  → %s\n' "$1"; }
die()  { printf 'publish-release: %s\n' "$1" >&2; exit 1; }

# shellcheck source=lib/version.sh
. "$ROOT/scripts/lib/version.sh"
VERSION="$(dt_release_version "$ROOT")"
DMG="$OUT/deviceterm-$VERSION.dmg"
CASK_DEST="$TAP_DIR/Casks/deviceterm.rb"

echo "publish-release: deviceterm v$VERSION"

[ -f "$DMG" ] || die "notarized DMG not found: $DMG (run 'make release' first)"

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
note "DMG sha256: $SHA"

# ── Render the cask from the template with the real version + sha256. ──
render_cask() {
    sed -e "s/^  version \".*\"/  version \"$VERSION\"/" \
        -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
        "$CASK_TEMPLATE"
}

# ── Sparkle appcast (EdDSA-signed) for the release DMG. ──
# `generate_appcast` reads the private key from the login Keychain and
# signs the enclosure. It writes appcast.xml next to the DMG; we set the
# enclosure URL prefix to the release-download path so the feed points at
# GitHub-hosted assets.
APPCAST="$OUT/appcast.xml"
generate_appcast_bin() {
    if [ -n "${SPARKLE_BIN_DIR:-}" ]; then echo "$SPARKLE_BIN_DIR/generate_appcast"
    else command -v generate_appcast || echo ""; fi
}
DL_PREFIX="https://github.com/sethdeckard/deviceterm/releases/download/v$VERSION"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "publish-release: DRY RUN"
    note "would render cask → $CASK_DEST (version $VERSION, sha $SHA)"
    render_cask | sed 's/^/      /'
    note "would generate appcast → $APPCAST (enclosure prefix $DL_PREFIX)"
    note "would: gh release create v$VERSION '$DMG' '$APPCAST'"
    note "would: git -C '$TAP_DIR' commit+push Casks/deviceterm.rb (after the release)"
    exit 0
fi

# ── Real run. ──
command -v gh >/dev/null 2>&1 || die "gh CLI not found"
gh auth status >/dev/null 2>&1 || die "not logged in to gh (run: gh auth login)"
[ -d "$TAP_DIR/Casks" ] || die "tap checkout not found at $TAP_DIR (set DEVICETERM_TAP_DIR)"

GEN_APPCAST="$(generate_appcast_bin)"
[ -n "$GEN_APPCAST" ] || die "generate_appcast not found (set SPARKLE_BIN_DIR)"

note "generating Sparkle appcast"
# `$OUT` holds both the notarized ZIP and the DMG for this version;
# generate_appcast rejects two archives of the same version. Stage just the
# DMG (the distributed artifact) so only it appears in the feed.
APPCAST_STAGE="$(mktemp -d -t deviceterm-appcast.XXXXXX)"
trap 'rm -rf "$APPCAST_STAGE"' EXIT
cp "$DMG" "$APPCAST_STAGE/"
# In-app release notes for the update pill's popover: generate_appcast
# embeds an HTML file named like the archive (deviceterm-<version>.html)
# as the appcast <description>. Provide it at release/release-notes-<v>.html.
NOTES_HTML="$OUT/release-notes-$VERSION.html"
if [ -f "$NOTES_HTML" ]; then
    cp "$NOTES_HTML" "$APPCAST_STAGE/deviceterm-$VERSION.html"
else
    note "no $NOTES_HTML; appcast will omit in-app release notes"
fi
"$GEN_APPCAST" --download-url-prefix "$DL_PREFIX/" -o "$APPCAST" "$APPCAST_STAGE"

# Create the GitHub release (with the DMG + appcast assets) BEFORE pushing
# the cask: its `url` points at the release-download path, so a
# release-creation/upload failure must not leave the public tap pointing at
# a DMG that doesn't exist yet.
note "creating GitHub release v$VERSION"
gh release create "v$VERSION" "$DMG" "$APPCAST" \
    --repo sethdeckard/deviceterm \
    --title "DeviceTerm $VERSION" \
    --notes-file "$OUT/release-notes-$VERSION.md" 2>/dev/null \
    || gh release create "v$VERSION" "$DMG" "$APPCAST" \
        --repo sethdeckard/deviceterm \
        --title "DeviceTerm $VERSION" \
        --generate-notes

note "rendering cask → $CASK_DEST"
render_cask > "$CASK_DEST"
git -C "$TAP_DIR" add "Casks/deviceterm.rb"
git -C "$TAP_DIR" commit -m "deviceterm $VERSION"
git -C "$TAP_DIR" push

echo "publish-release: v$VERSION published"
