#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/test-uitest.sh — the deliberate UI-test-harness track.
#
# Mirrors scripts/test-live.sh: a non-hermetic, human-run track kept out
# of `make verify` / `make test` because it needs things the hermetic gate
# can't guarantee — a real login session with an unlocked display, the
# harness's Screen Recording + Accessibility TCC grants, and a live
# deviceterm window. It proves the whole out-of-process loop end to end:
# the harness captures real pixels, reads deviceterm's AppKit AX tree, and
# a harness-driven GUI gesture changes CLI-observable state.
#
# Deliberately SIM-FREE. Every check here works on an empty deviceterm, so
# the track never boots or shuts down a simulator — the one thing a dev's
# running sims can't tolerate. (The sim/device scenarios in the skill
# playbook are driven interactively by an agent against a user-nominated
# throwaway sim, never automated here.)
#
# What it does NOT clean up: it leaves the resident harness and deviceterm
# running — both are dev instruments meant to persist. It only closes the
# one extra tab it opens.

set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=".build/debug"
UITEST="$BUILD/deviceterm-uitest"
CLI="$BUILD/deviceterm-cli"
AX_DUMP=".agents/skills/deviceterm-e2e/helpers/ax-dump.sh"
# The harness bundle installs to a stable, visible location (see
# uitest-bundle.sh) so its TCC grant survives rebuilds and `make clean`.
HARNESS_APP="${DEVICETERM_UITEST_APP:-$HOME/Applications/DeviceTermUITestHarness.app}"
DEVICETERM_APP="$BUILD/DeviceTerm.app"
# The harness bundle, its TCC grants, and the singleton GUI it drives
# are shared across this user's checkouts, and the uitest-bundle.sh call
# below replaces the one shared bundle. Every harness writer takes the uitest
# lock: this track holds it, uitest-bundle.sh acquires it unless told a
# caller already holds it, and the uitest-stop / uitest-run targets hold
# it across their own harness mutations. A concurrent run from another
# checkout refuses instead of corrupting the harness. The
# INT/TERM traps exit so a caught signal cannot release the lock and
# then keep driving the GUI; cleanup happens on EXIT only.
./scripts/exclusive-lock.sh acquire uitest $$
export DEVICETERM_UITEST_LOCK_HELD=1
SCRATCH="$(mktemp -d -t deviceterm-uitest.XXXXXX)"
trap 'rm -rf "$SCRATCH"; ./scripts/exclusive-lock.sh release uitest $$' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
info() { printf "  · %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1" >&2; exit 1; }

# Acquire one complete, trustworthy AX dump or stop the track immediately.
# ax-dump.sh already owns the one safe retry. A failure after that is an
# observation failure, not UI state that a caller may poll through.
require_ax_dump() {
    local out="$1"
    local context="$2"
    local diagnostic="$out.err"
    if ! "$AX_DUMP" >"$out" 2>"$diagnostic"; then
        [ ! -s "$diagnostic" ] || cat "$diagnostic" >&2
        fail "$context"
    fi
    rm -f "$diagnostic"
}

echo "test-uitest: harness + GUI smoke (deliberate, sim-free)"

# ── Build ──────────────────────────────────────────────────────────────
# The Makefile target already depends on `uitest-bundle` + `bundle`, but
# keep the script self-sufficient so it can be run directly.
echo "test-uitest: building harness, CLI, and DeviceTerm.app…"
# Full build, not just the two client products: make-app-bundle.sh
# assembles DeviceTerm.app from prebuilt binaries (the App, the daemon,
# and the shim/probe helpers) and hard-exits if any are missing — which
# is exactly what happens on a clean .build if we only build the harness
# and CLI. `swift build` produces every product the bundle needs.
swift build >/dev/null
./scripts/uitest-bundle.sh debug >/dev/null
./scripts/make-app-bundle.sh debug >/dev/null
[ -x "$UITEST" ] || fail "$UITEST not built"
[ -x "$CLI" ]    || fail "$CLI not built"
[ -d "$HARNESS_APP" ]    || fail "$HARNESS_APP missing"
[ -d "$DEVICETERM_APP" ] || fail "$DEVICETERM_APP missing"

# ── Small JSON reader (python3 ships with the Command Line Tools) ───────
# Total tab count summed across all windows in `window list --all --json`
# (an array of WorkspaceWindow objects). Prints -1
# if there are no windows.
#
# Deliberately the workspace total, not one window's count. ⌘T adds a tab
# to the frontmost window and ⌘W removes it, so the total moves by ±1
# whichever window is frontmost — and we never have to identify that
# window. That matters because `focused` here is derived from
# `workspace.selectedWindowID`, not a live window-server read: a focus
# change reaches it a notification later, and structural mutations set it
# outright, so a sampled row can disagree with the window the harness
# drives.
total_tabs() {
    python3 - "$1" <<'PY'
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
    print(sum(int(r.get("tabCount", 0)) for r in rows) if rows else -1)
except Exception:
    # Missing/empty/invalid JSON reads as "no window", never an abort.
    print(-1)
PY
}

# ── Pane readers, from the AX tree ─────────────────────────────────────
# Pane wrapper views publish a `deviceterm.pane.<kind>.<key>` accessibility
# identifier and answer AXFocused. `pane list` exposes the same leaf identity,
# but the AX tree is required here because this track verifies the AppKit
# accessibility surface and per-window responder focus.
#
# `pane_ids` lists every pane in the dump. `window_panes` lists the panes
# sharing a window with a named one, each tagged `1` or `0` for AXFocused.
# Both print one item per line and **nothing at all** when they find none,
# so `[ -s ]` means what it says. (`print("\n".join([]))` emits a bare
# newline, which reads as a non-empty file and would let "no pane is
# focused anywhere" pass for "focus moved".)
#
# **AXFocused is per window, not per app.** Every window keeps its own
# first responder, so a second deviceterm window contributes a second
# focused pane. Nothing here assumes app-wide uniqueness, and the focus
# checks scope to the window being driven. Otherwise another window's
# focused pane would satisfy an app-wide check on its own.
#
# Both print nothing when handed a failed, truncated, or unreadable dump, and
# `unreadable` must be present and false: a reply without that field cannot
# vouch for a childless tree. The flag answers for structural and identifying
# reads only (children, role, identifier), which are the ones that could drop a
# pane from these lists. Anything else is recorded on its own node and left for
# the reader, so `window_panes` checks each pane's own marker for AXFocused:
# the flag will not tell it that a focus read failed, and an unobserved focus
# would otherwise print as a definite 0. Every caller below first uses
# `require_ax_dump`, so that defensive parser behavior can never turn an
# acquisition failure into an absent pane.
pane_ids() {
    python3 - "$1" <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))
    if r.get("ok") is not True or r.get("truncated") or r.get("unreadable") is not False: raise SystemExit
    found = []
    def walk(node):
        if isinstance(node, dict):
            if str(node.get("identifier", "")).startswith("deviceterm.pane."):
                found.append(node["identifier"])
            for kid in node.get("children") or []: walk(kid)
    walk(r.get("tree"))
    for ident in sorted(found): print(ident)
except SystemExit:
    pass
except Exception:
    pass
PY
}

window_panes() {
    python3 - "$1" "$2" <<'PY'
import json, sys


class UnreadableFocus(Exception):
    """A pane's AXFocused read failed, so the focus column is not an answer."""


try:
    r = json.load(open(sys.argv[1]))
    if r.get("ok") is not True or r.get("truncated") or r.get("unreadable") is not False: raise SystemExit
    target, windows = sys.argv[2], []
    def walk(node, bucket):
        if not isinstance(node, dict): return
        # Each AXWindow starts a fresh bucket, so panes are grouped by the
        # window that owns them rather than by the whole app.
        if node.get("role") == "AXWindow":
            bucket = []
            windows.append(bucket)
        ident = str(node.get("identifier", ""))
        if bucket is not None and ident.startswith("deviceterm.pane."):
            # A failed AXFocused read is not an unfocused pane. It does not
            # raise the dump-wide flag, because it cannot hide a pane, so the
            # refusal has to happen here: the expression below maps a failed
            # read and an observed false to the same 0.
            marks = node.get("unreadable")
            unread = isinstance(marks, list) and "AXFocused" in marks
            bucket.append((ident, 1 if node.get("focused") else 0, unread))
        for kid in node.get("children") or []: walk(kid, bucket)
    walk(r.get("tree"), None)
    for bucket in windows:
        if any(ident == target for ident, _, _ in bucket):
            # One unreadable pane spoils the whole window's focus column: a
            # sibling reported 0 could equally be the pane that holds focus,
            # so a "focus moved to X" check would pass on a guess.
            if any(unread for _, _, unread in bucket): raise UnreadableFocus
            for ident, focused, _ in sorted(bucket): print("%s\t%d" % (ident, focused))
            break
# Exit 3, distinct from an empty-but-trustworthy answer, so a caller can tell
# "nothing to report" from "ask again". Every other bail stays silent-and-zero,
# preserving the `[ -s ]` contract above.
except UnreadableFocus:
    sys.exit(3)
except SystemExit:
    pass
except Exception:
    pass
PY
}

# `window_panes`, retrying while a pane's AXFocused read is unreadable.
#
# That refusal lands *downstream* of `require_ax_dump`'s own retry: the dump is
# structurally sound, so nothing upstream re-takes it, and a caller reading the
# empty output would report "focus is nowhere" for an observation never made.
# The first attempt uses the dump already in hand, so a readable tree costs
# nothing extra; only a refusal re-dumps (into the same path, which no caller
# reads again afterwards).
window_panes_settled() {
    local dump="$1" target="$2" out="$3" context="$4"
    local attempt
    for attempt in 1 2 3; do
        if [ "$attempt" -gt 1 ]; then
            sleep 0.25
            require_ax_dump "$dump" "$context"
        fi
        if window_panes "$dump" "$target" >"$out"; then return 0; fi
    done
    fail "$context: a pane's AXFocused read stayed unreadable across 3 dumps"
}

# ── Resident harness up + both TCC grants ──────────────────────────────
# Launch via `open` (LaunchServices), never as a child of this shell —
# TCC resolves grants through the responsible process, so a shell-spawned
# harness would attribute to the terminal.
if ! "$UITEST" ping >/dev/null 2>&1; then
    info "no resident harness — launching it"
    open "$HARNESS_APP" --args serve
    for _ in $(seq 1 20); do "$UITEST" ping >/dev/null 2>&1 && break; sleep 0.25; done
fi
"$UITEST" ping >/dev/null 2>&1 || fail "harness resident did not come up"
ok "harness resident is answering"

if "$UITEST" doctor >"$SCRATCH/doctor.json" 2>"$SCRATCH/doctor.err"; then
    ok "harness holds Screen Recording + Accessibility grants"
else
    cat "$SCRATCH/doctor.err" >&2
    fail "harness is missing a TCC grant — grant DeviceTermUITestHarness (not deviceterm, not your terminal) in System Settings, then re-run"
fi

# ── deviceterm running with a window ───────────────────────────────────
# Refuse a DeviceTerm process from another checkout before the first
# daemon call; otherwise the CLI could validate the wrong build.
# If process enumeration is unavailable, the guard proceeds without BUSY.
./scripts/instance-guard.sh refuse-foreign

# Reject this checkout's visible processes when they predate the rebuilt
# app. Do not kill them because the app may hold user tabs. If process
# enumeration is unavailable, skip this freshness check.
dt_bin="$DEVICETERM_APP/Contents/MacOS/deviceterm"
if [ -x "$dt_bin" ]; then
    bin_age="$(( $(date +%s) - $(stat -f %m "$dt_bin") ))"
    for dt_pid in $(./scripts/instance-guard.sh list-mine); do
        proc_age="$(ps -o etimes= -p "$dt_pid" 2>/dev/null | tr -d ' ' || true)"
        if [[ "$proc_age" =~ ^[0-9]+$ ]] && [ "$proc_age" -gt "$bin_age" ]; then
            fail "deviceterm (pid $dt_pid) started ${proc_age}s ago, before this build (${bin_age}s old) — quit it and re-run, or every row below describes the old binary"
        fi
    done
fi

if ! "$CLI" window list --all --json >"$SCRATCH/windows.json" 2>/dev/null \
   || [ "$(total_tabs "$SCRATCH/windows.json")" -lt 0 ]; then
    info "deviceterm has no window — launching it"
    open "$DEVICETERM_APP"
    for _ in $(seq 1 40); do
        "$CLI" window list --all --json >"$SCRATCH/windows.json" 2>/dev/null || true
        [ "$(total_tabs "$SCRATCH/windows.json")" -ge 0 ] && break
        sleep 0.5
    done
fi
# The ±1 arithmetic assumes no other actor mutates the workspace tab
# total mid-run. The uitest lock plus the refusal above hold that for
# every cooperating checkout; a sandbox denied process enumeration could
# still miss a foreign instance.
baseline="$(total_tabs "$SCRATCH/windows.json")"
[ "$baseline" -ge 0 ] || fail "deviceterm has no window (a locked/asleep display launches it window-less) — unlock the screen and retry"
ok "deviceterm is up with a window (total tabs=$baseline)"

# ── Capture produces a real image ──────────────────────────────────────
"$UITEST" capture window --out "$SCRATCH/win.png" >"$SCRATCH/cap.json" 2>&1 \
    || { cat "$SCRATCH/cap.json" >&2; fail "capture window failed"; }
python3 - "$SCRATCH/cap.json" "$SCRATCH/win.png" <<'PY' || fail "capture reply/PNG invalid"
import json, os, sys
r = json.load(open(sys.argv[1]))
assert r.get("ok") is True, "reply not ok"
assert int(r.get("width", 0)) > 0 and int(r.get("height", 0)) > 0, "zero dimensions"
assert os.path.getsize(sys.argv[2]) > 0, "empty PNG"
PY
ok "capture window wrote a non-empty PNG"

# ── AX dump is well-formed and not the known degenerate tree ───────────
# ax-dump.sh retries the known transient once and emits only a complete,
# non-truncated tree. Its final diagnostic must remain visible on failure.
require_ax_dump "$SCRATCH/ax.json" "ax dump remained unusable after its retry"
ok "ax dump returned a well-formed tree"

# ── The end-to-end proof: a harness GUI gesture moves CLI state ────────
# Post ⌘T (New Tab) and confirm the workspace's total tab count — read
# back through the CLI — went up by one. This is the whole point: an
# out-of-process GUI drive changed state the CLI can see. A key equivalent
# rather than a click, because the harness activates deviceterm first, so ⌘T
# resolves against the frontmost window exactly as a user's would. It also
# sidesteps a naming collision: "New Tab" labels both the menu item and the
# strip's "+", so a click by that label lands on whichever the tree walk
# reaches first.
"$UITEST" drive key cmd+t >"$SCRATCH/drive.json" 2>&1 \
    || { cat "$SCRATCH/drive.json" >&2; fail "drive key cmd+t failed"; }
after=-1
for _ in $(seq 1 12); do
    "$CLI" window list --all --json >"$SCRATCH/windows2.json" 2>/dev/null || true
    after="$(total_tabs "$SCRATCH/windows2.json")"
    [ "$after" -eq "$((baseline + 1))" ] && break
    sleep 0.25
done
[ "$after" -eq "$((baseline + 1))" ] \
    || fail "New Tab drive did not add a tab (total tabs $baseline → $after)"
ok "harness-driven 'New Tab' added a tab (total tabs $baseline → $after)"

# ── Pane-level proof: a split adds a pane, an arrow moves focus ────────
# Runs inside the tab ⌘T just opened, so the panes created here leave with
# it. `window list` counts tabs, not panes, which is why these read the
# AX tree instead.
#
# Everything below is phrased against the ONE identifier the split
# creates, never against an app-wide count or a unique focused pane. The
# dump spans every window, and only the selected tab's panes are in the
# view hierarchy, so absolute numbers are not the harness's to predict.
require_ax_dump "$SCRATCH/panes0.json" "ax dump before split failed"
pane_ids "$SCRATCH/panes0.json" >"$SCRATCH/ids0.txt"
[ -s "$SCRATCH/ids0.txt" ] \
    || fail "no pane carried an accessibility identifier (truncated dump, or the pane wrappers stopped publishing one)"

"$UITEST" drive key cmd+d >"$SCRATCH/split.json" 2>&1 \
    || { cat "$SCRATCH/split.json" >&2; fail "drive key cmd+d failed"; }
new_pane=""
for _ in $(seq 1 12); do
    require_ax_dump "$SCRATCH/panes1.json" "ax dump while waiting for split failed"
    pane_ids "$SCRATCH/panes1.json" >"$SCRATCH/ids1.txt"
    new_pane="$(comm -13 "$SCRATCH/ids0.txt" "$SCRATCH/ids1.txt")"
    [ "$(printf '%s' "$new_pane" | grep -c .)" -eq 1 ] && break
    sleep 0.25
done
[ "$(printf '%s' "$new_pane" | grep -c .)" -eq 1 ] \
    || fail "Split Right did not add exactly one pane (added: ${new_pane:-none})"
ok "harness-driven 'Split Right' added a pane ($new_pane)"

# ⌘D focuses the pane it creates. `TerminalPaneViewController`'s
# viewDidAppear claims first responder, after the layout reconcile has
# restored the pane that was focused before. So the arrow has somewhere to
# come back from, and the direction is deliberate: the new pane is on the
# right, so Left goes back to the pane that was split.
#
# Named panes on both sides. "focus is no longer on the new pane" would
# also be true if the action merely dropped focus on the floor, which is
# exactly how a broken forward from the pane's root view behaves.
window_panes_settled "$SCRATCH/panes1.json" "$new_pane" "$SCRATCH/wp1.txt" \
    "ax dump after the split"
grep -qxF "$(printf '%s\t1' "$new_pane")" "$SCRATCH/wp1.txt" \
    || fail "the new pane did not report AXFocused after the split"
source_pane="$(awk -F'\t' -v new="$new_pane" '$1 != new { print $1 }' "$SCRATCH/wp1.txt")"
[ "$(printf '%s' "$source_pane" | grep -c .)" -eq 1 ] \
    || fail "expected exactly one other pane in the split window, found: ${source_pane:-none}"

"$UITEST" drive key opt+cmd+left >"$SCRATCH/focus.json" 2>&1 \
    || { cat "$SCRATCH/focus.json" >&2; fail "drive key opt+cmd+left failed"; }
moved=""
for _ in $(seq 1 12); do
    require_ax_dump "$SCRATCH/panes2.json" "ax dump while waiting for focus failed"
    # An unreadable focus read empties the file, which this loop already reads
    # as "not yet" and answers by re-dumping. Tolerated here, unlike at the
    # one-shot sites, precisely because the retry exists. Without the `|| true`
    # the distinct status would abort the run under `set -e`.
    window_panes "$SCRATCH/panes2.json" "$new_pane" >"$SCRATCH/wp2.txt" || true
    if grep -qxF "$(printf '%s\t1' "$source_pane")" "$SCRATCH/wp2.txt"; then
        moved="yes"
        break
    fi
    sleep 0.25
done
[ -n "$moved" ] \
    || fail "Select Pane Left did not focus $source_pane (window now: $(tr '\n' ' ' <"$SCRATCH/wp2.txt"))"
ok "harness-driven 'Select Pane Left' moved focus $new_pane → $source_pane"

# ── A rearrange keeps focus on the pane it moved ───────────────────────
# ⇧⌘→ rebuilds the whole split hierarchy, which detaches and re-adds every
# pane view. Each terminal claims first responder the first time it reaches
# a window, so an unguarded re-claim would hand focus to whichever pane
# came last in display order instead of the one the user moved.
"$UITEST" drive key cmd+shift+right >"$SCRATCH/move.json" 2>&1 \
    || { cat "$SCRATCH/move.json" >&2; fail "drive key cmd+shift+right failed"; }
kept=""
for _ in $(seq 1 12); do
    require_ax_dump "$SCRATCH/panes2b.json" "ax dump while waiting for rearrange failed"
    # Same as the focus loop above: an unreadable read is "not yet", and the
    # `|| true` keeps the distinct status from aborting under `set -e`.
    window_panes "$SCRATCH/panes2b.json" "$new_pane" >"$SCRATCH/wp2b.txt" || true
    if grep -qxF "$(printf '%s\t1' "$source_pane")" "$SCRATCH/wp2b.txt"; then
        kept="yes"
        break
    fi
    sleep 0.25
done
[ -n "$kept" ] \
    || fail "Move Pane Right lost focus from $source_pane (window now: $(tr '\n' ' ' <"$SCRATCH/wp2b.txt"))"
ok "harness-driven 'Move Pane Right' kept focus on $source_pane"

# ── ⌘W closes the focused pane, and only the focused pane ──────────────
# Two terminal panes in this tab, so ⌘W names the focused one. Focus is
# on $source_pane after the arrow above, so that is the identifier that
# has to disappear. The workspace tab total is the control: it must hold,
# or the chord took the whole tab instead of one pane.
"$UITEST" drive key cmd+w >"$SCRATCH/closepane.json" 2>&1 \
    || { cat "$SCRATCH/closepane.json" >&2; fail "drive key cmd+w failed"; }
closed=""
for _ in $(seq 1 12); do
    require_ax_dump "$SCRATCH/panes3.json" "ax dump while waiting for pane close failed"
    pane_ids "$SCRATCH/panes3.json" >"$SCRATCH/ids3.txt"
    # An empty list means a failed or truncated dump, never an empty
    # window, so require panes to be present before reading one's
    # absence as the close.
    if [ -s "$SCRATCH/ids3.txt" ] && ! grep -qxF "$source_pane" "$SCRATCH/ids3.txt"; then
        closed="yes"
        break
    fi
    sleep 0.25
done
[ -n "$closed" ] \
    || fail "Close Pane did not drop $source_pane (panes now: $(tr '\n' ' ' <"$SCRATCH/ids3.txt"))"
"$CLI" window list --all --json >"$SCRATCH/windows3.json" 2>/dev/null || true
held="$(total_tabs "$SCRATCH/windows3.json")"
[ "$held" -eq "$((baseline + 1))" ] \
    || fail "Close Pane took the tab with it (total tabs $((baseline + 1)) → $held)"
ok "harness-driven 'Close Pane' dropped $source_pane and kept the tab"

# Assert focus here to prove the reconcile handed it off. Without this
# row the tab-strip fallback would still close the tab with focus lost
# entirely, and the count assertion below would pass for the wrong
# reason.
window_panes_settled "$SCRATCH/panes3.json" "$new_pane" "$SCRATCH/wp3.txt" \
    "ax dump after the pane close"
grep -qxF "$(printf '%s\t1' "$new_pane")" "$SCRATCH/wp3.txt" \
    || fail "the surviving pane did not report AXFocused after the close (window now: $(tr '\n' ' ' <"$SCRATCH/wp3.txt"))"
ok "focus landed on the surviving pane ($new_pane)"

# ── ⌘W degrades to Close Tab on the tab's last terminal ────────────────
# One terminal left, and a tab must keep at least one, so the same chord
# now names the whole tab. Terminal-only, so no close modal.
# This also returns the workspace to the count it started at.
"$UITEST" drive key cmd+w >/dev/null 2>&1 || true
final=-1
for _ in $(seq 1 12); do
    "$CLI" window list --all --json >"$SCRATCH/windows4.json" 2>/dev/null || true
    final="$(total_tabs "$SCRATCH/windows4.json")"
    [ "$final" -eq "$baseline" ] && break
    sleep 0.25
done
[ "$final" -eq "$baseline" ] \
    || fail "⌘W on the tab's last terminal did not close the tab (total tabs=$final); close the extra tab by hand"
ok "harness-driven ⌘W closed the last-terminal tab (total tabs back to $baseline)"

# ── Not covered here: the chord-less main-menu items ───────────────────
# AXPress finds a main-menu item but returns `ok:true` whether or not the
# action dispatched: items are validated when their menu opens, and
# nothing here opens one. Rename Tab… and Duplicate Tab have no chord
# either, so both are checked by hand in
# `Tests/Manual/keyboard-shortcuts.md` §3.7 and §3.8.

echo "test-uitest: ok"
