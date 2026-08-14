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

ok()   { printf "  ✓ %s\n" "$1"; }
skip() { printf "  · %s (not present yet — skipping)\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1" >&2; exit 1; }

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
