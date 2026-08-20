#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# scripts/verify.sh — single-command verification gate.
#
# Each sub-check self-skips when its backing source/script doesn't exist.
# As Sources/, Tests/, and scripts/ populate, the matching checks become
# real. Lint already ran via `make verify` (which depends on `lint`); this
# script runs the rest.

set -euo pipefail

cd "$(dirname "$0")/.."

ok()     { printf "  ✓ %s\n" "$1"; }
skip()   { printf "  · %s (not present yet — skipping)\n" "$1"; }
# Use for host-denied capabilities; `skip` is reserved for missing backing
# files.
denied() { printf "  · %s — skipping\n" "$1"; }
fail()   { printf "  ✗ %s\n" "$1" >&2; exit 1; }

echo "verify:"

# ──────────────────────────────────────────────────────────────────────
# Pre-flight: refuse to enter the lock-wait pit
# ──────────────────────────────────────────────────────────────────────
#
# SwiftPM blocks indefinitely (no timeout) when another instance holds
# `.build/`'s lock, printing only "Another instance of SwiftPM ... is
# already running, waiting until that process has finished execution"
# — a message normally hidden behind `make verify | tail -40`. The
# common cause is an auto-backgrounded `swift test` from a prior
# session that survived its parent shell (orphans reparent to init;
# `pkill -9` can miss them if filtered the wrong way). The wait can
# stretch into multiple minutes before anyone notices.
#
# Surface it loudly instead. Detection is scoped two ways to dodge
# false positives:
#   - Only SwiftPM tooling is considered — `swift-test` /
#     `swiftpm-testing-helper`. The user's running app + daemon
#     binaries live under `.build/` too, so a naked path match would
#     trip on every dev session.
#   - The match further requires that the tooling process belongs to
#     THIS checkout. `swiftpm-testing-helper` carries the bundle's
#     full path in its argv — easy substring match. `swift-test`
#     itself doesn't, so we read its CWD via `lsof` to confirm.
this_build="$(pwd -P)/.build"
this_repo="$(pwd -P)"
running=$(pgrep -f "swiftpm-testing-helper.*$this_build" 2>/dev/null || true)
for pid in $(pgrep -x swift-test 2>/dev/null || true); do
    cwd=$(lsof -a -d cwd -p "$pid" 2>/dev/null | awk 'NR==2 {print $NF}')
    [ "$cwd" = "$this_repo" ] && running="$running $pid"
done
# `grep -v '^$'` exits non-zero when its input has no matches (the
# common, expected case — no stale swift-test running). Without the
# `|| true`, `set -e` silently kills the script here with exit 1 and
# the operator sees a bare "verify:" with no diagnostic.
running=$(echo "$running" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ' || true)
if [ -n "$running" ]; then
    echo "  ✗ another swift-test on this checkout is already running:" >&2
    ps -o pid,etime,command -p $running 2>&1 | sed 's/^/      /' >&2
    echo "      kill them (\`kill -9 $(echo $running | tr '\n' ' ')\`) or wait, then retry." >&2
    exit 1
fi

# ──────────────────────────────────────────────────────────────────────
# Always-on
# ──────────────────────────────────────────────────────────────────────

# Makefile-targets-exist: every target documented in `make help` is also
# declared in the Makefile so we don't ship dead docs.
declared=$(awk '/^\.PHONY:/{flag=1} flag{print; if(/[^\\]$/) flag=0}' Makefile \
            | tr -d '\\' | tr -s ' \t\n' '\n' | grep -v '^\.PHONY:$' | grep -v '^$' | sort -u)
documented=$(awk '/^\t@echo "  make /{print $4}' Makefile | sort -u)
missing=$(comm -23 <(echo "$documented") <(echo "$declared") || true)
if [ -z "$missing" ]; then
    ok "all documented Make targets are declared in .PHONY"
else
    fail "documented but undeclared: $missing"
fi

# Exclusive-lock self-test: needs no hardware, and uses host process
# state to construct live, dead, and absent process-group cases. Pins the
# mkdir-lock semantics (contended acquire refuses with exit 75; release
# permits re-acquire; a dead holder is reclaimed only when nothing
# survives in its group) and the BUSY line-1 key order against drift. A
# throwaway track name keeps a real test-live or test-uitest lock
# untouched.
if [ -x scripts/exclusive-lock.sh ]; then
    lk_track="verify-selftest.$$"
    lk_dir="/tmp/deviceterm.$(id -u).${lk_track}.lock"
    trap 'rm -rf "$lk_dir" "$lk_dir.recover"' EXIT
    ./scripts/exclusive-lock.sh acquire "$lk_track" $$ \
        || fail "exclusive-lock: fresh acquire failed"
    set +e
    lk_out=$(./scripts/exclusive-lock.sh acquire "$lk_track" $$ 2>&1)
    lk_rc=$?
    set -e
    [ "$lk_rc" -eq 75 ] \
        || fail "exclusive-lock: contended acquire exited $lk_rc, want 75"
    echo "$lk_out" | grep -qE '^deviceterm-make: BUSY: resource=lock:[^ ]+ pid=[0-9]+ holder=.' \
        || fail "exclusive-lock: BUSY line 1 missing or its key order drifted"
    ./scripts/exclusive-lock.sh release "$lk_track" $$
    ./scripts/exclusive-lock.sh acquire "$lk_track" $$ \
        || fail "exclusive-lock: re-acquire after release failed"
    ./scripts/exclusive-lock.sh release "$lk_track" $$
    # Staleness. The holder identity is written by hand so the verdict
    # does not depend on this shell's job control: a real track's group
    # dies with its job, but a wrapper spawned inside a non-interactive
    # script shares that script's group and would look alive.
    lk_dead=$(sh -c 'echo $$')      # exited before the assignment returns
    lk_stamp() {
        printf '%s\nGone\n%s\n%s\n%s\n' "$1" "$(pwd -P)" "$lk_track" "$2" \
            > "$lk_dir/holder"
    }
    # Find a process group that is genuinely absent here; a live group
    # owning the number would make the reclaim case below assert the
    # opposite of what it means to.
    lk_absent=""
    for lk_cand in 99999 99997 99993 99991 99989; do
        lk_err=$(kill -0 -- -"$lk_cand" 2>&1) && continue
        case "$(printf '%s' "$lk_err" | tr 'A-Z' 'a-z')" in
            *"no such process"*) lk_absent="$lk_cand"; break ;;
        esac
    done
    [ -n "$lk_absent" ] \
        || fail "exclusive-lock: no absent process group to test against"
    # Dead holder, no survivors in its group: reclaimable.
    ./scripts/exclusive-lock.sh acquire "$lk_track" $$ >/dev/null
    lk_stamp "$lk_dead" "$lk_absent"
    ./scripts/exclusive-lock.sh acquire "$lk_track" $$ \
        || fail "exclusive-lock: stale-holder reclaim failed"
    # Dead holder whose group still has survivors: a SIGKILLed wrapper
    # can leave a swift test child driving the resource, so refuse. The
    # unknown-group case refuses for the same reason, and is asserted
    # with the sentinel so it holds where process info is denied too.
    for lk_group in "unknown" "$(ps -p $$ -o pgid= 2>/dev/null | tr -d ' ' || true)"; do
        [ -n "$lk_group" ] || continue
        lk_stamp "$lk_dead" "$lk_group"
        set +e
        ./scripts/exclusive-lock.sh acquire "$lk_track" $$ >/dev/null 2>&1
        lk_rc=$?
        set -e
        [ "$lk_rc" -eq 75 ] \
            || fail "exclusive-lock: reclaimed past group '$lk_group' (exit $lk_rc, want 75)"
    done
    # A recovery mutex owned by a live process blocks reclaiming, however
    # old it is; age alone must not clear it, or a stalled reclaimer's
    # peer could delete the lock the reclaimer went on to grant.
    lk_stamp "$lk_dead" "$lk_absent"
    mkdir -p "$lk_dir.recover"
    printf '%s\n%s\n%s\n%s\n%s\n' \
        $$ "$(ps -p $$ -o lstart= | sed 's/^ *//;s/ *$//')" "$(pwd -P)" \
        "$lk_track" "$(ps -p $$ -o pgid= | tr -d ' ')" > "$lk_dir.recover/holder"
    touch -t 202001010000 "$lk_dir.recover"
    set +e
    ./scripts/exclusive-lock.sh acquire "$lk_track" $$ >/dev/null 2>&1
    lk_rc=$?
    set -e
    [ "$lk_rc" -eq 75 ] \
        || fail "exclusive-lock: live recovery mutex ignored (exit $lk_rc, want 75)"
    rm -rf "$lk_dir.recover"
    ./scripts/exclusive-lock.sh acquire "$lk_track" $$ \
        || fail "exclusive-lock: reclaim after clearing recovery mutex failed"
    ./scripts/exclusive-lock.sh release "$lk_track" $$
    ok "exclusive-lock self-test (BUSY format + staleness)"
else
    skip "exclusive-lock self-test (no scripts/exclusive-lock.sh)"
fi

# Instance-guard self-test: a process whose `comm` is RELATIVE must still
# resolve to an absolute executable path. launchd starts the daemon through
# the LaunchAgent's bundle-relative `BundleProgram`, so every demand-launched
# helper looks exactly like this. A guard that cannot resolve one classifies
# nothing, and `make run` then walks straight into another checkout's daemon
# with no BUSY.
if [ -x scripts/instance-guard.sh ]; then
    ig_tmp=$(mktemp -d "/tmp/deviceterm-guard-selftest.XXXXXX")
    ig_pid=""
    # `lk_dir` is unset when the block above skipped, and `set -u` would make
    # the trap itself fail; `${lk_dir:+…}` drops those words entirely then.
    trap 'rm -rf ${lk_dir:+"$lk_dir" "$lk_dir.recover"} "$ig_tmp"; \
          [ -n "$ig_pid" ] && kill "$ig_pid" 2>/dev/null; true' EXIT
    # Name the fixture per-run. A parallel checkout's verify spawns its own,
    # and a shared name would let each match the other's pid.
    ig_exe="relexe.$$"
    cp /bin/sleep "$ig_tmp/$ig_exe"
    # Re-sign the copied fixture ad hoc before launch so AMFI accepts it.
    codesign -f -s - "$ig_tmp/$ig_exe" >/dev/null 2>&1 \
        || fail "instance-guard: could not ad-hoc sign the fixture"
    ( cd "$ig_tmp" && exec "./$ig_exe" 60 >/dev/null 2>&1 & )
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        ig_pid=$(pgrep -f "\./$ig_exe 60" 2>/dev/null | head -1 || true)
        [ -n "$ig_pid" ] && break
        sleep 0.2
    done
    # An empty pgrep means "cannot see" rather than "nothing there". That is
    # the rule the guard itself follows, since a sandboxed shell can be denied
    # process enumeration. Probe the same `-f` full-argv mode the fixture
    # lookup and `classify_all` use, restricting the match-all probe to this
    # user with `-U`: macOS gates argv separately from process names, and `.`
    # is the match-all pattern pgrep documents as a required operand. A probe
    # that wrongly reports "denied" would turn a genuine launch failure into a
    # silent skip, so it stays on the real call's capability.
    if [ -z "$ig_pid" ] && ! pgrep -U "$(id -u)" -f . >/dev/null 2>&1; then
        denied "instance-guard self-test (pgrep denied)"
    elif [ -z "$ig_pid" ]; then
        fail "instance-guard: fixture process never appeared"
    else
        # Precondition: without a relative comm this proves nothing, since the
        # absolute path would resolve through plain path arithmetic.
        ig_comm=$(ps -p "$ig_pid" -o comm= 2>/dev/null || true)
        case "$ig_comm" in
            /*) fail "instance-guard: fixture comm '$ig_comm' is absolute, not relative" ;;
            "") fail "instance-guard: fixture comm unreadable" ;;
        esac
        ig_want="$(cd "$ig_tmp" && pwd -P)/$ig_exe"
        # Start time pins the fixture's identity, so a later reading can tell
        # the same process from an unrelated one that inherited a recycled pid.
        ig_start=$(ps -p "$ig_pid" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//' || true)
        ig_got=$(./scripts/instance-guard.sh resolve-exe "$ig_pid" || true)
        if [ -z "$ig_got" ] && ! lsof -a -p $$ -d txt -Fn >/dev/null 2>&1; then
            denied "instance-guard relative-comm resolution (lsof denied)"
        elif [ "$ig_got" != "$ig_want" ]; then
            fail "instance-guard: resolve-exe gave '$ig_got', want '$ig_want'"
        else
            # Unlinking the fixture models `make run`, which rebuilds the
            # bundle (`rm -rf "$APP"`, then recreate) BEFORE `ensure-clear`
            # classifies anything. macOS terminates a process whose executable
            # is unlinked, so the fixture may be gone before this second
            # lookup; empty is then the guard's documented no-identification
            # outcome and is correct. Any other answer is a defect: a decorated
            # path (Linux lsof appends " (deleted)") would fail
            # `classify_all`'s basename check, and an unrelated absolute path
            # can leave the process unclassified or misclassify ownership.
            # Only the unclassified case silently lets kill-own skip the stale
            # daemon, leaving the new app to connect straight to it.
            rm -f "$ig_tmp/$ig_exe"
            ig_got=$(./scripts/instance-guard.sh resolve-exe "$ig_pid" || true)
            # Liveness is read AFTER the lookup, and that order is what makes
            # empty decidable. Matching the start time confirms this is still
            # the fixture rather than a recycled pid, and a fixture alive now
            # was alive throughout the lookup; an empty answer there is a real
            # failure to identify, and `classify_all` would skip that stale
            # daemon. A fixture already gone may have died mid-lookup, where
            # empty is the no-identification outcome.
            ig_now=$(ps -p "$ig_pid" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//' || true)
            if [ -n "$ig_start" ] && [ "$ig_now" = "$ig_start" ]; then
                ig_live=yes
            else
                ig_live=no
            fi
            case "$ig_got" in
                "$ig_want") ;;
                "") [ "$ig_live" = no ] \
                        || fail "instance-guard: unlinked exe of live pid $ig_pid resolved empty" ;;
                *)  fail "instance-guard: unlinked exe gave '$ig_got', want '$ig_want' or empty" ;;
            esac
            ok "instance-guard self-test (relative comm resolves; unlinked exe never misreports)"
        fi
    fi
    kill "$ig_pid" 2>/dev/null || true
    ig_pid=""
    rm -rf "$ig_tmp"
else
    skip "instance-guard self-test (no scripts/instance-guard.sh)"
fi

# ──────────────────────────────────────────────────────────────────────
# Filesystem-gated
# ──────────────────────────────────────────────────────────────────────

# The live tracks (CoreSimulatorLiveTests, DeviceLiveTests) are excluded
# here on purpose: they need a booted sim / a connected physical device
# and drive non-hermetic, slow I/O. They're deliberate, separate tracks —
# not silently state-gated — run via `make test-live` / `make
# test-device-live`. The `·` lines keep that visible so the exclusions are
# never a surprise.
swift test --no-parallel --skip CoreSimulatorLiveTests --skip DeviceLiveTests >/dev/null \
    && ok "swift test (excludes live tracks)" \
    || fail "swift test failed — run 'make test' for the full output"
printf "  · CoreSimulatorLiveTests — live-sim track, run 'make test-live' deliberately\n"
printf "  · DeviceLiveTests — physical-device track, run 'make test-device-live' deliberately\n"

if [ -d Tests/DaemonIntegrationTests ]; then
    swift test --filter DaemonIntegrationTests      >/dev/null && ok "DaemonIntegrationTests" || fail "DaemonIntegrationTests"
else
    skip "DaemonIntegrationTests (no Tests/DaemonIntegrationTests/)"
fi

if [ -d Sources/CompatProbe ]; then
    swift run deviceterm-probe                         >/dev/null && ok "deviceterm-probe"        || fail "deviceterm-probe"
else
    skip "deviceterm-probe (no Sources/CompatProbe/)"
fi

# GUI smoke: script-driven harness. The bundle must be present
# (`make bundle`) for the script to launch the app — verify rebuilds
# it on demand so a fresh checkout's `make verify` works without
# requiring a prior `make run`.
if [ -x scripts/gui-smoke.sh ]; then
    ./scripts/make-app-bundle.sh debug                >/dev/null 2>&1 \
      && ./scripts/gui-smoke.sh debug                 >/dev/null \
      && ok "gui-smoke" || fail "gui-smoke"
elif [ -d Tests/GUISmokeTests ]; then
    swift test --filter GUISmokeTests               >/dev/null && ok "GUISmokeTests"        || fail "GUISmokeTests"
else
    skip "gui-smoke (no scripts/gui-smoke.sh)"
fi

if [ -d Tests/ShimTests ]; then
    swift test --filter ShimTests                   >/dev/null && ok "ShimTests"            || fail "ShimTests"
else
    skip "ShimTests (no Tests/ShimTests/)"
fi

if [ -d Tests/CLITests ]; then
    swift test --filter CLITests                    >/dev/null && ok "CLITests"             || fail "CLITests"
else
    skip "CLITests (no Tests/CLITests/)"
fi

if [ -x scripts/build-release.sh ]; then
    ./scripts/build-release.sh --dry-run             && ok "release dry-run"                || fail "release dry-run"
else
    skip "release dry-run (no scripts/build-release.sh)"
fi

echo "verify: ok"
