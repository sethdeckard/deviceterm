#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ax-dump.sh: return one trustworthy DeviceTerm accessibility dump.
#
# The resident can occasionally miss its reply deadline or return the known
# degenerate/truncated tree. Retry that read once, then fail without emitting
# an empty result that a caller could mistake for an empty UI. A serviced
# ok:false refusal is final and is never retried.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/deviceterm-ax-dump.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

for attempt in 1 2; do
    reply="$scratch/reply.$attempt.json"
    errors="$scratch/reply.$attempt.err"
    validation="$scratch/validation.$attempt.err"
    client_rc=0
    "$here/uitest.sh" ax dump "$@" >"$reply" 2>"$errors" || client_rc=$?

    validation_rc=0
    python3 - "$reply" 2>"$validation" <<'PY' || validation_rc=$?
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as stream:
        report = json.load(stream)
except Exception as error:
    print(f"ax-dump.sh: unreadable reply ({error})", file=sys.stderr)
    raise SystemExit(11)

if not isinstance(report, dict):
    print("ax-dump.sh: reply is not a JSON object", file=sys.stderr)
    raise SystemExit(11)
if report.get("ok") is False:
    print(
        f"ax-dump.sh: dump reports ok:false ({report.get('error', 'no reason given')})",
        file=sys.stderr,
    )
    raise SystemExit(10)
if report.get("ok") is not True:
    print("ax-dump.sh: reply does not report ok:true", file=sys.stderr)
    raise SystemExit(11)
if report.get("truncated"):
    print("ax-dump.sh: dump is truncated", file=sys.stderr)
    raise SystemExit(11)

roles = set()


def walk(node):
    if not isinstance(node, dict):
        return
    role = node.get("role")
    if role:
        roles.add(role)
    for child in node.get("children") or []:
        walk(child)


walk(report.get("tree"))
if not roles - {"AXApplication"}:
    print("ax-dump.sh: dump contains only AXApplication nodes", file=sys.stderr)
    raise SystemExit(11)
PY

    if [ "$validation_rc" -eq 0 ] && [ "$client_rc" -eq 0 ]; then
        cat "$reply"
        exit 0
    fi

    # A complete ok:false reply is a real refusal. Retrying would hide it
    # behind a second request and cannot make the first one trustworthy.
    if [ "$validation_rc" -eq 10 ]; then
        cat "$validation" >&2
        exit 1
    fi

    if [ "$attempt" -eq 2 ]; then
        [ ! -s "$errors" ] || cat "$errors" >&2
        cat "$validation" >&2
        exit 1
    fi
done
