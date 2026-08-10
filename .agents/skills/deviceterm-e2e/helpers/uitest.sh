#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# uitest.sh — invoke the deviceterm-uitest harness client from anywhere.
#
# The harness is a dev/test instrument, deliberately NOT symlinked onto a
# tab's PATH the way the shipped `deviceterm` CLI is. This wrapper lets a
# scenario call it regardless of the agent's working directory: it prefers
# a copy on PATH, else the debug build product located *relative to this
# script*, which sits at a fixed path inside the repo checkout. So
# `helpers/uitest.sh capture window …` works whether the agent's cwd is the
# repo root or somewhere else entirely.
#
# Exits 3 (matching the client's own "no resident" code) with a build hint
# if the harness hasn't been built.

set -euo pipefail

if command -v deviceterm-uitest >/dev/null 2>&1; then
    exec deviceterm-uitest "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
bin="$repo_root/.build/debug/deviceterm-uitest"
if [ ! -x "$bin" ]; then
    echo "uitest.sh: harness not built at $bin — run 'make uitest-run'" >&2
    exit 3
fi
exec "$bin" "$@"
