#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/lib/version.sh: the single reader of the public release
# version, sourced by every script that needs it so the extraction
# cannot drift between them.
#
# The version's source of truth is `DeviceTermVersion.current` in
# Sources/DaemonProtocol/DeviceTermVersion.swift; everything else (the
# bundled Info.plists, DMG name, git tag, cask) derives from it at
# build/publish time.
#
# Sourced by absolute path because a sourced POSIX script cannot learn
# its own location, so callers pass the repo root:
#
#   . "$ROOT/scripts/lib/version.sh"
#   VERSION="$(dt_release_version "$ROOT")"
#
# The assignment must be a standalone statement: a failing $(…) inside
# another command's argument does not trip `set -e`, but a failing
# plain assignment does.

# dt_release_version <repo-root>
#   Prints the release version (X.Y.Z). If the source file or current
#   line cannot be parsed, writes an error to stderr and returns
#   nonzero. Never falls back to a placeholder.
dt_release_version() {
    dt_ver_file="$1/Sources/DaemonProtocol/DeviceTermVersion.swift"
    if [ ! -f "$dt_ver_file" ]; then
        echo "version.sh: release-version source not found: $dt_ver_file" >&2
        return 1
    fi
    dt_ver="$(sed -n \
        's/^[[:space:]]*public static let current[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' \
        "$dt_ver_file" | head -n 1)"
    if ! printf '%s' "$dt_ver" \
        | grep -qxE '(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'; then
        echo "version.sh: cannot parse release version from $dt_ver_file (got '${dt_ver:-nothing}')" >&2
        return 1
    fi
    printf '%s\n' "$dt_ver"
}
