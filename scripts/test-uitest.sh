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
# The harness bundle installs to a stable, visible location (see
# uitest-bundle.sh) so its TCC grant survives rebuilds and `make clean`.
HARNESS_APP="${DEVICETERM_UITEST_APP:-$HOME/Applications/DeviceTermUITestHarness.app}"
DEVICETERM_APP="$BUILD/DeviceTerm.app"
SCRATCH="$(mktemp -d -t deviceterm-uitest.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
info() { printf "  · %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1" >&2; exit 1; }

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
# Total tab count summed across ALL windows in `windows list --all --json`
# (a bare array of {index,isKey,tabCount,selectedTabShortId?}). Prints -1
# if there are no windows.
#
# Deliberately the workspace total, not one window's count. ⌘T adds a tab
# to the frontmost window and ⌘W removes it, so the total moves by ±1
# whichever window is frontmost — and we never have to identify that
# window. That matters because `isKey` here is deviceterm's Router-selected
# window (`workspace.selectedWindowID`), which is NOT the AppKit key/
# frontmost window the harness actually drives; the two diverge when a
# window is focused without a Router route, so keying off a single row
# would validate against the wrong window.
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
# identifier and answer AXFocused. That is the only way in: pane identity
# lives in GUI nav state the CLI never exposes, and `panes list` is a
# daemon RPC that enumerates device panes only, so it can neither see nor
# count terminal panes.
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
# Both print nothing on a failed or truncated dump. The tree has depth and
# node ceilings, and a pane dropped for budget would otherwise read as a
# pane that does not exist.
pane_ids() {
    python3 - "$1" <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))
    if r.get("ok") is not True or r.get("truncated"): raise SystemExit
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
try:
    r = json.load(open(sys.argv[1]))
    if r.get("ok") is not True or r.get("truncated"): raise SystemExit
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
            bucket.append((ident, 1 if node.get("focused") else 0))
        for kid in node.get("children") or []: walk(kid, bucket)
    walk(r.get("tree"), None)
    for bucket in windows:
        if any(ident == target for ident, _ in bucket):
            for ident, focused in sorted(bucket): print("%s\t%d" % (ident, focused))
            break
except SystemExit:
    pass
except Exception:
    pass
PY
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
# This script rebuilds the app but reuses whatever deviceterm is already
# running, so a process started before the build under test silently
# validates the *old* binary and every row below passes for the wrong
# reason. Compare the running process's age against the freshly built
# executable's and stop when the process is older. Reported rather than
# killed: the running app holds the user's tabs, which are not this
# script's to close.
# Matched on the bundle-relative path, not `$DEVICETERM_APP`: the process
# runs from `.build/arm64-apple-macosx/debug/…` while that variable names
# the `.build/debug` symlink, so the two argv strings never compare equal.
# `|| true` because `pgrep` exits 1 when nothing matches, which under
# `set -euo pipefail` would abort the script on the ordinary path where
# deviceterm simply isn't running yet.
dt_bin="$DEVICETERM_APP/Contents/MacOS/deviceterm"
dt_pid="$(pgrep -f 'DeviceTerm\.app/Contents/MacOS/deviceterm' 2>/dev/null | head -1 || true)"
if [ -n "$dt_pid" ] && [ -x "$dt_bin" ]; then
    proc_age="$(ps -o etimes= -p "$dt_pid" 2>/dev/null | tr -d ' ' || true)"
    bin_age="$(( $(date +%s) - $(stat -f %m "$dt_bin") ))"
    if [[ "$proc_age" =~ ^[0-9]+$ ]] && [ "$proc_age" -gt "$bin_age" ]; then
        fail "deviceterm (pid $dt_pid) started ${proc_age}s ago, before this build (${bin_age}s old) — quit it and re-run, or every row below describes the old binary"
    fi
fi

if ! "$CLI" windows list --all --json >"$SCRATCH/windows.json" 2>/dev/null \
   || [ "$(total_tabs "$SCRATCH/windows.json")" -lt 0 ]; then
    info "deviceterm has no window — launching it"
    open "$DEVICETERM_APP"
    for _ in $(seq 1 40); do
        "$CLI" windows list --all --json >"$SCRATCH/windows.json" 2>/dev/null || true
        [ "$(total_tabs "$SCRATCH/windows.json")" -ge 0 ] && break
        sleep 0.5
    done
fi
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
# The degenerate tree (an AXApplication nested in itself, truncated:true)
# is a known intermittent; retry once before failing so a flake doesn't
# fail the track. A real tree contains chrome roles beyond AXApplication.
ax_ok() {
    "$UITEST" ax dump >"$SCRATCH/ax.json" 2>&1 || return 1
    python3 - "$SCRATCH/ax.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
if r.get("ok") is not True: raise SystemExit(1)
roles = set()
def walk(n):
    if isinstance(n, dict):
        role = n.get("role")
        if role: roles.add(role)
        for c in n.get("children", []) or []: walk(c)
walk(r.get("tree"))
# Degenerate: nothing but AXApplication nodes.
raise SystemExit(0 if roles - {"AXApplication"} else 1)
PY
}
if ax_ok; then
    ok "ax dump returned a well-formed tree"
elif ax_ok; then
    ok "ax dump returned a well-formed tree (after one retry)"
else
    fail "ax dump was empty or degenerate on two tries"
fi

# ── The end-to-end proof: a harness GUI gesture moves CLI state ────────
# Post ⌘T (New Tab) and confirm the workspace's total tab count — read
# back through the CLI — went up by one. This is the whole point: an
# out-of-process GUI drive changed state the CLI can see. A key equivalent
# (not a click on the "+" affordance, whose "New Tab" AX label lives on a
# non-pressable image) because the harness activates deviceterm first, so
# ⌘T resolves against the frontmost window exactly as a user's would.
"$UITEST" drive key cmd+t >"$SCRATCH/drive.json" 2>&1 \
    || { cat "$SCRATCH/drive.json" >&2; fail "drive key cmd+t failed"; }
after=-1
for _ in $(seq 1 12); do
    "$CLI" windows list --all --json >"$SCRATCH/windows2.json" 2>/dev/null || true
    after="$(total_tabs "$SCRATCH/windows2.json")"
    [ "$after" -eq "$((baseline + 1))" ] && break
    sleep 0.25
done
[ "$after" -eq "$((baseline + 1))" ] \
    || fail "New Tab drive did not add a tab (total tabs $baseline → $after)"
ok "harness-driven 'New Tab' added a tab (total tabs $baseline → $after)"

# ── Pane-level proof: a split adds a pane, an arrow moves focus ────────
# Runs inside the tab ⌘T just opened, so the panes created here leave with
# it. `windows list` counts tabs, not panes, which is why these read the
# AX tree instead.
#
# Everything below is phrased against the ONE identifier the split
# creates, never against an app-wide count or a unique focused pane. The
# dump spans every window, and only the selected tab's panes are in the
# view hierarchy, so absolute numbers are not the harness's to predict.
"$UITEST" ax dump >"$SCRATCH/panes0.json" 2>&1 || fail "ax dump before split failed"
pane_ids "$SCRATCH/panes0.json" >"$SCRATCH/ids0.txt"
[ -s "$SCRATCH/ids0.txt" ] \
    || fail "no pane carried an accessibility identifier (truncated dump, or the pane wrappers stopped publishing one)"

"$UITEST" drive key cmd+d >"$SCRATCH/split.json" 2>&1 \
    || { cat "$SCRATCH/split.json" >&2; fail "drive key cmd+d failed"; }
new_pane=""
for _ in $(seq 1 12); do
    "$UITEST" ax dump >"$SCRATCH/panes1.json" 2>/dev/null || true
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
window_panes "$SCRATCH/panes1.json" "$new_pane" >"$SCRATCH/wp1.txt"
grep -qxF "$(printf '%s\t1' "$new_pane")" "$SCRATCH/wp1.txt" \
    || fail "the new pane did not report AXFocused after the split"
source_pane="$(awk -F'\t' -v new="$new_pane" '$1 != new { print $1 }' "$SCRATCH/wp1.txt")"
[ "$(printf '%s' "$source_pane" | grep -c .)" -eq 1 ] \
    || fail "expected exactly one other pane in the split window, found: ${source_pane:-none}"

"$UITEST" drive key opt+cmd+left >"$SCRATCH/focus.json" 2>&1 \
    || { cat "$SCRATCH/focus.json" >&2; fail "drive key opt+cmd+left failed"; }
moved=""
for _ in $(seq 1 12); do
    "$UITEST" ax dump >"$SCRATCH/panes2.json" 2>/dev/null || true
    window_panes "$SCRATCH/panes2.json" "$new_pane" >"$SCRATCH/wp2.txt"
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
    "$UITEST" ax dump >"$SCRATCH/panes2b.json" 2>/dev/null || true
    window_panes "$SCRATCH/panes2b.json" "$new_pane" >"$SCRATCH/wp2b.txt"
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
    "$UITEST" ax dump >"$SCRATCH/panes3.json" 2>/dev/null || true
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
"$CLI" windows list --all --json >"$SCRATCH/windows3.json" 2>/dev/null || true
held="$(total_tabs "$SCRATCH/windows3.json")"
[ "$held" -eq "$((baseline + 1))" ] \
    || fail "Close Pane took the tab with it (total tabs $((baseline + 1)) → $held)"
ok "harness-driven 'Close Pane' dropped $source_pane and kept the tab"

# Assert focus here to prove the reconcile handed it off. Without this
# row the tab-strip fallback would still close the tab with focus lost
# entirely, and the count assertion below would pass for the wrong
# reason.
window_panes "$SCRATCH/panes3.json" "$new_pane" >"$SCRATCH/wp3.txt"
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
    "$CLI" windows list --all --json >"$SCRATCH/windows4.json" 2>/dev/null || true
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
