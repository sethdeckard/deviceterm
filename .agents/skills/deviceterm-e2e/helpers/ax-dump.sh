#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ax-dump.sh: return one trustworthy DeviceTerm accessibility dump.
#
# The resident can occasionally miss its reply deadline or return a truncated
# tree. Retry that read once, then fail without emitting an empty result that a
# caller could mistake for an empty UI. A serviced ok:false refusal is final and
# is never retried.
#
# "Empty" is judged against the target. Only the GUI app is expected to have
# UI; a faceless agent such as the daemon publishes a childless root whenever
# it is showing nothing, and that is an answer rather than a failure.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/deviceterm-ax-dump.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# Which target was asked for, so the "no UI at all" check can apply only to
# the GUI app. A faceless agent legitimately publishes a childless root: that
# is how the daemon reports a hidden status item.
target="com.deviceterm"
prev=""
for arg in "$@"; do
    case "$arg" in
        --bundle-id=*) target="${arg#--bundle-id=}" ;;
        *) [ "$prev" = "--bundle-id" ] && target="$arg" ;;
    esac
    prev="$arg"
done

for attempt in 1 2; do
    reply="$scratch/reply.$attempt.json"
    errors="$scratch/reply.$attempt.err"
    validation="$scratch/validation.$attempt.err"
    client_rc=0
    "$here/uitest.sh" ax dump "$@" >"$reply" 2>"$errors" || client_rc=$?

    validation_rc=0
    python3 - "$reply" "$target" 2>"$validation" <<'PY' || validation_rc=$?
import json
import sys

path = sys.argv[1]
target = sys.argv[2]
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
# Some node failed a structural or identifying read, so this tree's shape or a
# node's identity is in doubt. Distinct from truncated, where a ceiling ran
# out. `unreadable` separates a failed child, role, or identifier read from a
# genuine absence: without it a failed child read looks childless and a failed
# identifier looks like a node that carries none.
#
# Narrower than "any read failed". A title or a value that would not read is
# recorded on its own node and left there, because it cannot hide a node or
# misclassify one. Real trees carry such nodes routinely (a sim pane mounts
# system-vended controls that fail a read on every dump), and refusing over one
# takes away the AX vantage point entirely.
#
# The field must be *present*. A reply without it cannot vouch for its own
# completeness, and treating that silence as "readable" restores exactly the
# false-childless result this check exists to catch. One cause is a resident
# built before the flag existed, since the resident is long-lived and keeps
# answering across a rebuild until restarted. Retrying does not clear that, so
# this is final rather than retried.
if "unreadable" not in report:
    print(
        "ax-dump.sh: reply has no 'unreadable' field, so its completeness "
        "cannot be verified. Restart the resident: "
        "make uitest-stop && make uitest-run",
        file=sys.stderr,
    )
    raise SystemExit(10)
if report["unreadable"]:
    # Name the attributes so the failure is diagnosable from the message. A
    # bare `true` marker offers no name to collect, hence the type guard; the
    # refusal itself stands either way.
    failed = set()

    def collect(node):
        if not isinstance(node, dict):
            return
        marks = node.get("unreadable")
        if isinstance(marks, list):
            failed.update(marks)
        for child in node.get("children") or []:
            collect(child)

    collect(report.get("tree"))
    print(
        "ax-dump.sh: dump failed a structural or identifying read "
        f"({', '.join(sorted(failed)) or 'attribute not named'}), so the "
        "tree's shape or a node's identity is in doubt",
        file=sys.stderr,
    )
    raise SystemExit(11)

roles = set()
application_nodes = 0


def walk(node):
    global application_nodes
    if not isinstance(node, dict):
        return
    role = node.get("role")
    if role:
        roles.add(role)
        # A marked application node was recorded but not entered, so only
        # unmarked ones count toward the nested-application check below.
        if role == "AXApplication" and not node.get("cycle") and not node.get("skipped"):
            application_nodes += 1
    for child in node.get("children") or []:
        walk(child)


tree = report.get("tree")
walk(tree)

# Every dump starts from an application element, so the root must say
# AXApplication. Reject a missing or wrong role even when nothing was marked
# unreadable, so the shape is checked independently of the read flags.
if not isinstance(tree, dict) or tree.get("role") != "AXApplication":
    print("ax-dump.sh: dump root is not an AXApplication node", file=sys.stderr)
    raise SystemExit(11)

# An application element never legitimately contains another. This compares
# roles, not identities, so an unmarked nested one establishes only that the
# walk entered it: neither traversal guard stopped the node.
if application_nodes > 1:
    print("ax-dump.sh: dump contains an unmarked nested AXApplication", file=sys.stderr)
    raise SystemExit(11)

# A root with nothing under it means a bad read only for a target expected to
# have UI. The daemon is a faceless agent, and a childless root is its correct,
# complete answer when the status item is hidden. Failing there would report a
# harness fault for a working read.
if target == "com.deviceterm" and not roles - {"AXApplication"}:
    print("ax-dump.sh: dump contains only AXApplication nodes", file=sys.stderr)
    raise SystemExit(11)
PY

    if [ "$validation_rc" -eq 0 ] && [ "$client_rc" -eq 0 ]; then
        cat "$reply"
        exit 0
    fi

    # Conditions a second request cannot improve: a serviced ok:false refusal,
    # and a reply with no unreadable field. Retrying would hide either behind
    # another round trip without making the first one trustworthy.
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
