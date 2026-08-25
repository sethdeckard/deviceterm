#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# bump-version.sh: set a new public release version.
#
# Usage: scripts/bump-version.sh <x.y.z>   (or `make bump VERSION=x.y.z`)
#
# Rewrites the only two files that carry the release version: the
# `DeviceTermVersion.current` source of truth and README.md's DMG
# download line. Everything else (bundled Info.plists, DMG name, git
# tag, cask) derives at build/publish time via scripts/lib/version.sh,
# and the release dry-run in `make verify` fails if these two files
# disagree.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { printf 'bump-version: %s\n' "$1" >&2; exit 1; }

NEW="${1:-}"
# SemVer forbids leading zeroes in the numeric components.
printf '%s' "$NEW" \
    | grep -qxE '(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)' \
    || die "usage: scripts/bump-version.sh <x.y.z> (got '${NEW:-nothing}')"

# shellcheck source=lib/version.sh
. "$ROOT/scripts/lib/version.sh"
CURRENT="$(dt_release_version "$ROOT")"

# The new version must be greater. Compare component-wise; BSD sort has
# no version sort to lean on.
IFS=. read -r c1 c2 c3 <<<"$CURRENT"
IFS=. read -r n1 n2 n3 <<<"$NEW"
newer=0
if   [ "$n1" -gt "$c1" ]; then newer=1
elif [ "$n1" -eq "$c1" ] && [ "$n2" -gt "$c2" ]; then newer=1
elif [ "$n1" -eq "$c1" ] && [ "$n2" -eq "$c2" ] && [ "$n3" -gt "$c3" ]; then newer=1
fi
[ "$newer" -eq 1 ] || die "new version $NEW is not greater than current $CURRENT"

TRUTH="$ROOT/Sources/DaemonProtocol/Environment/DeviceTermVersion.swift"
README="$ROOT/README.md"

# Prepare and validate both rewrites before replacing either file, so
# validation failures leave both originals unchanged.
TRUTH_TMP="$(mktemp "${TMPDIR:-/tmp}/deviceterm-bump.XXXXXX")"
README_TMP="$(mktemp "${TMPDIR:-/tmp}/deviceterm-bump.XXXXXX")"
trap 'rm -f "$TRUTH_TMP" "$README_TMP"' EXIT

# Anchored to line start so the doc comment's `= "X.Y.Z"` example
# doesn't match.
sed "s/^\([[:space:]]*public static let current[[:space:]]*=[[:space:]]*\)\"[^\"]*\"/\1\"$NEW\"/" \
    "$TRUTH" > "$TRUTH_TMP"
grep -qE "^[[:space:]]*public static let current[[:space:]]*=[[:space:]]*\"$NEW\"" "$TRUTH_TMP" \
    || die "rewrite of $TRUTH did not produce $NEW"

sed "s/deviceterm-[0-9][0-9.]*\.dmg/deviceterm-$NEW.dmg/g" "$README" > "$README_TMP"
grep -qF "deviceterm-$NEW.dmg" "$README_TMP" \
    || die "no deviceterm-<version>.dmg download line found in README.md"
stale="$(grep -oE 'deviceterm-[0-9][0-9.]*\.dmg' "$README_TMP" \
    | grep -vxF "deviceterm-$NEW.dmg" | sort -u || true)"
[ -z "$stale" ] \
    || die "stale DMG references would remain in README.md: $(printf '%s' "$stale" | tr '\n' ' ')"

# README first: if the truth-file write does not start, it still holds
# $CURRENT and the same bump can be rerun. `cat >` keeps each target's
# mode; `mv` would install mktemp's 0600.
cat "$README_TMP" > "$README"
cat "$TRUTH_TMP" > "$TRUTH"

echo "bump-version: $CURRENT → $NEW"
echo "  Sources/DaemonProtocol/Environment/DeviceTermVersion.swift"
echo "  README.md"
echo "bump-version: run 'make verify' before committing"
