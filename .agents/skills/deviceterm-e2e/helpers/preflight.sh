#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# preflight.sh — fail loud before any E2E scenario runs.
#
# The four things a false pass hides: the harness resident isn't running,
# it lacks its TCC grants (so capture/drive silently error), deviceterm
# isn't up with a real window, or the host tab holds no automation grant
# (so every scenario that opens or arranges a surface is refused). Check
# all four here so a scenario never "passes" against a machine that
# couldn't have observed anything.
#
# Prints a one-line status per check and exits non-zero on the first
# failure, echoing the exact remediation. Run it from the repo root.

set -euo pipefail
cd "$(dirname "$0")/../../../.."   # helpers → deviceterm-e2e → skills → .agents → repo root

# Resolve the two client binaries. The harness goes through the shared
# cwd-independent wrapper (PATH → repo-relative build product). The CLI is
# on PATH inside a tab (symlinked into the session bin/); off-PATH the
# fallback is `deviceterm-cli`, the CLI product — NOT `.build/debug/
# deviceterm`, which is the GUI *app* and would launch and block instead of
# answering.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
uitest() { "$here/uitest.sh" "$@"; }
dt() {
    if command -v deviceterm >/dev/null 2>&1; then deviceterm "$@"
    else .build/debug/deviceterm-cli "$@"; fi
}

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
info() { printf "  · %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1" >&2; exit 1; }

echo "deviceterm-e2e preflight:"

# 1. Harness resident is answering and holds both grants. `doctor` reports
#    the *resident's* grants (not this shell's), exits 0 only when both are
#    present, and prints the exact System Settings remediation on failure.
if uitest doctor >/tmp/dt-e2e-doctor.json 2>/tmp/dt-e2e-doctor.err; then
    ok "harness resident + Screen Recording + Accessibility grants"
else
    code=$?
    if [ "$code" = 3 ]; then
        fail "no harness resident — run 'make uitest-run' (launches the bundled .app so its TCC grants attribute to the harness, not your terminal)"
    fi
    cat /tmp/dt-e2e-doctor.err >&2
    fail "harness is running but a TCC grant is missing (see remediation above)"
fi

# 2. deviceterm is running. Inside a tab — where this skill runs —
#    deviceterm injects DEVICETERM_SESSION into the shell, a sandbox-safe
#    signal any process can read. Do NOT use pgrep here: an agent's Bash is
#    often sandboxed and denied the process-argv enumeration pgrep needs, so
#    it returns empty even while deviceterm is plainly running (that was a
#    real false negative). The window check below is the actual proof over
#    the daemon socket; this gate just gives a clearer message for the
#    common in-tab case.
if [ -n "${DEVICETERM_SESSION:-}" ]; then
    ok "inside a deviceterm tab (deviceterm is running)"
else
    info "DEVICETERM_SESSION unset — not inside a deviceterm tab; the window check below confirms deviceterm over the daemon socket"
fi

# 3. deviceterm has at least one window the harness can capture. `windows
#    list --all --json` is the CLI ground truth: a bare JSON array of
#    {index,isKey,tabCount,selectedTabShortId?}. `--all` is required —
#    without it the listing is scoped to the caller's own session, so it
#    misses every window but the agent's own tab (and is empty from a
#    non-tab shell). An empty array means a window-less launch (a known
#    libghostty failure on a locked/asleep display), which no capture can
#    rescue.
if dt windows list --all --json >/tmp/dt-e2e-windows.json 2>/tmp/dt-e2e-windows.err; then
    # Every window object carries an "index" key; its absence means the
    # array is empty (`[]`).
    if grep -q '"index"' /tmp/dt-e2e-windows.json; then
        ok "deviceterm has at least one window"
    else
        fail "deviceterm is running but reports no windows — quit it fully and reopen on an unlocked display"
    fi
else
    # A non-zero exit here usually means the daemon has no GUI back-channel
    # (DeviceTerm.app isn't running or hasn't subscribed yet), not a broken
    # daemon — surface its own message so the cause is unambiguous.
    cat /tmp/dt-e2e-windows.err >&2
    fail "couldn't list windows — deviceterm's GUI isn't running (or its daemon back-channel isn't up yet); run 'make run', then retry"
fi

# 4. The host tab holds a live automation grant. Scenarios open, select,
#    and move tabs and windows, and those verbs need a grant that only
#    the GUI issues. Check `allowedMethods`, NOT
#    $DEVICETERM_SESSION_ROLE: the role is descriptive metadata that
#    survives a grant that never landed or was revoked, which is exactly
#    the false pass this file exists to prevent. `allowedMethods` is
#    derived from the live grant, so it can't lie.
#
#    Probe with `tab.capture`, which no scenario runs. Probing a
#    workspace verb the scenarios do run would make this gate depend on
#    the same scope tagging it exists to check, so a verb tagged wrong
#    would report a grant this tab does not hold.
#
#    `doctor` exits non-zero when any of its own checks fail, for reasons
#    that have nothing to do with authority, so read the report rather
#    than the exit status. Gate 3 already proved the daemon and GUI are
#    up, so an absent `tab.capture` here means no grant.
dt doctor --json >/tmp/dt-e2e-cli-doctor.json 2>/tmp/dt-e2e-cli-doctor.err || true
if grep -q '"tab\.capture"' /tmp/dt-e2e-cli-doctor.json; then
    ok "host tab holds a live automation grant"
else
    fail "host tab holds no automation grant — open an Automation Tab (Shell > Open Automation Tab, ⇧⌘T) and rerun the skill from it"
fi

echo "preflight ok — scenarios may run."
