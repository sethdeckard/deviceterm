#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/make-help-book.sh: build DeviceTerm.help from docs/USAGE.md.
#
# Two steps the generator deliberately does not do itself, because both
# need the pages on disk first:
#
#   1. the book's Info.plist, whose HPDBook* keys tell Help Viewer which
#      page to open and which index to search;
#   2. the CoreSpotlight index, built by Apple's hiutil over the rendered
#      pages.
#
# Output: .build/<config>/DeviceTerm.help, which make-app-bundle.sh copies
# into the app's Contents/Resources.
#
# The book is a bundle nested inside the app bundle, so it is signed along
# with everything else when the app is signed. Nothing here signs.

set -eu

CONFIG="${1:-debug}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/$CONFIG"

# shellcheck source=lib/version.sh
. "$ROOT/scripts/lib/version.sh"
VERSION="$(dt_release_version "$ROOT")"

GUIDE="$ROOT/docs/USAGE.md"
BOOK="$BUILD/DeviceTerm.help"
# The title is a contract in three places: HPDBookTitle here, the app's
# CFBundleHelpBookName, and what Help Viewer shows. They have to match.
TITLE="DeviceTerm Help"
INDEX="DeviceTerm.cshelpindex"

if [ ! -f "$GUIDE" ]; then
    echo "make-help-book: $GUIDE not found" >&2
    exit 1
fi

if ! command -v hiutil >/dev/null 2>&1; then
    echo "make-help-book: hiutil not found (ships with macOS)" >&2
    exit 1
fi

swift build -c "$CONFIG" --product deviceterm-helpbook

LPROJ="$BOOK/Contents/Resources/en.lproj"
rm -rf "$BOOK"
mkdir -p "$LPROJ"

"$BUILD/deviceterm-helpbook" "$GUIDE" "$LPROJ" "$TITLE"

cat > "$BOOK/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>com.deviceterm.help</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${TITLE}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>HPDBookAccessPath</key>
    <string>index.html</string>
    <key>HPDBookIndexPath</key>
    <string>${INDEX}</string>
    <key>HPDBookTitle</key>
    <string>${TITLE}</string>
    <key>HPDBookType</key>
    <string>3</string>
</dict>
</plist>
PLIST

# -I corespotlight writes the .cshelpindex format declared above in
# HPDBookIndexPath. -a indexes anchors so a deep link is reachable, and
# -s/-l pin the language rather than inheriting the builder's locale.
hiutil -I corespotlight -Cagvf "$LPROJ/$INDEX" -s en -l en "$LPROJ" >/dev/null

echo "make-help-book: built $BOOK ($(ls "$LPROJ"/*.html | wc -l | tr -d ' ') pages)"
