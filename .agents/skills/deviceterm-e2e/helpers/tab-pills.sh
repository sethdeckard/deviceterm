#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# tab-pills.sh — list the tab pills in deviceterm's accessibility tree.
#
# Counting pills is the flagship cross-check's central operation, and the
# predicate has three ways to go wrong when it is written out by hand: count a
# pill's ✕, count the strip's "+", or match on role instead of identifier. It
# lives here once so a scenario doesn't have to restate it.
#
# A pill is a node whose `identifier` starts `deviceterm.tab.`, does not end
# `.close`, and is not `deviceterm.tab.new`. Prints one identifier per line,
# sorted. Identifiers rather than a count because the cleanup paths need to know
# *which* tabs are new, not how many.
#
#   tab-pills.sh              take a fresh dump through uitest.sh
#   tab-pills.sh <dump.json>  read a dump already on disk
#
# Unlike `pane_ids` in scripts/test-uitest.sh, which prints nothing when it
# can't trust the dump, this exits non-zero and says why. `pane_ids` is one
# clause of a larger script that checks emptiness for itself; run directly, an
# empty list is indistinguishable from "no tabs", so a failed or truncated dump
# would read as a real count.
#
# That exit status is the only thing standing between a caller and the reading
# above, so redirect and check it rather than piping:
#
#   tab-pills.sh >pills.txt && wc -l <pills.txt
#
# `tab-pills.sh | wc -l` reports `wc`'s status instead, which is 0, and prints
# 0 for a dump this refused. `pipefail` is off by default in bash and zsh.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: tab-pills.sh [<ax-dump.json>]"; }

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

if [ "$#" -eq 1 ]; then
    dump="$1"
    [ -r "$dump" ] || { echo "tab-pills.sh: cannot read $dump" >&2; exit 2; }
else
    dump="$(mktemp "${TMPDIR:-/tmp}/tab-pills.XXXXXX")"
    trap 'rm -f "$dump"' EXIT
    # A failing client says why in `{"ok":false,"error":…}` on *stdout* and
    # writes nothing to stderr, so its reason is now sitting in $dump. Don't
    # let the non-zero exit stop us short of reading it: the ok:false arm below
    # quotes that reason, and bailing here would report an exit code and no
    # explanation at all.
    "$here/uitest.sh" ax dump >"$dump" || true
fi

python3 - "$dump" <<'PY'
import json, sys

path = sys.argv[1]
try:
    report = json.load(open(path))
except Exception as err:
    sys.exit(f"tab-pills.sh: {path} is not a readable ax dump ({err})")

if report.get("ok") is not True:
    sys.exit(f"tab-pills.sh: the dump reports ok:false ({report.get('error', 'no reason given')})")
if report.get("truncated"):
    sys.exit("tab-pills.sh: the dump is truncated, so pills are missing from it — re-dump")

found = []


def walk(node):
    if not isinstance(node, dict):
        return
    ident = str(node.get("identifier", ""))
    if (ident.startswith("deviceterm.tab.")
            and not ident.endswith(".close")
            and ident != "deviceterm.tab.new"):
        found.append(ident)
    for kid in node.get("children") or []:
        walk(kid)


walk(report.get("tree"))
for ident in sorted(found):
    print(ident)
PY
