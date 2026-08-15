# deviceterm — single dev command surface. See AGENTS.md "Commands" for the spec.
#
# Each target self-skips when its backing thing (Sources subdirectory,
# script, etc.) doesn't exist yet. Once the backing thing lands, the target
# runs the real command and fails loudly if it errors. The filesystem is
# the truth.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
# Apple ships GNU Make 3.81, which predates .SHELLFLAGS and ignores it,
# so a recipe cannot rely on `set -e` being active: a command that fails
# mid-recipe does not stop the commands after it. Anything whose failure
# must abort the recipe says so explicitly, with `|| exit $$?` or an
# `|| { ...; exit 1; }` block. Newer make honors the flags, and the
# explicit form is correct under both.

.PHONY: help \
        build run kill-daemon daemon cli shim probe \
        uitest uitest-bundle uitest-run uitest-stop \
        test test-int test-shim test-gui test-live test-device-live test-uitest \
        lint verify clean \
        release publish \
        hooks

# Default goal: print help so a bare `make` is friendly.
.DEFAULT_GOAL := help

# ──────────────────────────────────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────────────────────────────────

help:
	@echo "deviceterm Makefile — see AGENTS.md for the command reference."
	@echo ""
	@echo "Common:"
	@echo "  make build       Build in debug"
	@echo "  make run         Build + relaunch this checkout's DeviceTerm.app"
	@echo "                   (refuses if another checkout's instance runs)"
	@echo "  make kill-daemon Stop this checkout's app + daemon"
	@echo "  make test        Unit tests"
	@echo "  make lint        SwiftLint --strict"
	@echo "  make verify      Single-command gate (body grows as code lands)"
	@echo ""
	@echo "Milestone-gated (self-skip when backing source/script absent):"
	@echo "  make probe       CoreSimulator compatibility probe"
	@echo "  make daemon      Build deviceterm-daemon"
	@echo "  make cli         Build deviceterm-cli"
	@echo "  make shim        Build deviceterm-shim"
	@echo "  make uitest      Build deviceterm-uitest (UI-test harness)"
	@echo "  make uitest-run  Bundle + launch the harness; report TCC grants"
	@echo "  make test-int    Daemon integration tests"
	@echo "  make test-gui    GUI smoke (scripts/gui-smoke.sh; runs in verify)"
	@echo "  make test-shim   Shim+CLI argv/stdio tests"
	@echo "  make test-live   Live-sim track (boots a clean sim; deliberate)"
	@echo "                   DEVICETERM_LIVE_DEVICE_FAMILY=watch boots a watch"
	@echo "                   (runs the watchOS Digital Crown tests)"
	@echo "  make test-device-live  Live physical-device track (needs a"
	@echo "                   connected, unlocked iPhone/iPad + OS tunnel)"
	@echo "  make test-uitest UI-harness GUI smoke (needs TCC grants +"
	@echo "                   an unlocked display; sim-free; deliberate)"
	@echo "  make release     Signed, notarized DMG"
	@echo ""
	@echo "Setup:"
	@echo "  make hooks       Install + check .githooks (one-time after clone)"
	@echo "  make clean       rm -rf .build"

# ──────────────────────────────────────────────────────────────────────────
# Build
# ──────────────────────────────────────────────────────────────────────────

build:
	@if find Sources -name '*.swift' 2>/dev/null | head -1 | grep -q .; then \
	    swift build; \
	else \
	    echo "make build: no Swift sources yet — skipping"; \
	fi

bundle: build
	@if [ -d Sources/App ]; then \
	    ./scripts/make-app-bundle.sh debug; \
	else \
	    echo "make bundle: Sources/App/ does not exist — skipping"; \
	fi

# Stop THIS checkout's running deviceterm app + embedded daemon. The daemon
# is demand-launched by launchd and a killed instance keeps the *old* inode,
# so without this a rebuilt `make run` can keep serving stale code (e.g.
# "method not found" for a freshly-added RPC). The guard classifies each
# process by its executable's physical path and signals only pids running
# from this checkout's .build — another worktree's instance and an
# installed /Applications/DeviceTerm.app are never touched.
kill-daemon:
	@if [ -x scripts/instance-guard.sh ]; then \
	    ./scripts/instance-guard.sh kill-own; \
	else \
	    echo "make kill-daemon: scripts/instance-guard.sh absent — skipping"; \
	fi

# The guard runs after `bundle` (so the binary is already rebuilt) and
# before `open` (so the next demand-launch execs the fresh daemon). A
# foreign instance — another worktree's build or /Applications — makes the
# guard refuse with a BUSY block instead of killing it: quit that instance
# from its own checkout; there is no force flag.
run: bundle
	@if [ -d Sources/App ]; then \
	    test -x .build/debug/DeviceTerm.app/Contents/MacOS/deviceterm \
	      || { echo "make run: bundle missing or incomplete" >&2; exit 1; }; \
	    ./scripts/instance-guard.sh ensure-clear || exit $$?; \
	    open .build/debug/DeviceTerm.app; \
	else \
	    echo "make run: Sources/App/ does not exist — skipping"; \
	fi

daemon:
	@if [ -d Sources/DeviceTermDaemon ]; then \
	    swift build --product deviceterm-daemon; \
	elif [ -d Sources/Daemon ]; then \
	    swift build --target Daemon; \
	else \
	    echo "make daemon: Sources/Daemon/ does not exist — skipping"; \
	fi

cli:
	@if [ -d Sources/DeviceTermCLI ]; then \
	    swift build --target DeviceTermCLI; \
	else \
	    echo "make cli: Sources/DeviceTermCLI/ does not exist — skipping"; \
	fi

shim:
	@if [ -d Sources/Shim ]; then \
	    swift build --target Shim; \
	else \
	    echo "make shim: Sources/Shim/ does not exist — skipping"; \
	fi

uitest:
	@if [ -d Sources/DeviceTermUITest ]; then \
	    swift build --product deviceterm-uitest; \
	else \
	    echo "make uitest: Sources/DeviceTermUITest/ does not exist — skipping"; \
	fi

uitest-bundle: uitest
	@if [ -x scripts/uitest-bundle.sh ]; then \
	    ./scripts/uitest-bundle.sh; \
	else \
	    echo "make uitest-bundle: scripts/uitest-bundle.sh does not exist — skipping"; \
	fi

# Stopping the resident mid-track would corrupt another checkout's
# running test-uitest, so the pkill happens while holding the uitest
# lock; a held lock turns this into a BUSY refusal. The lock is taken in
# the same shell as the pkill, since a separate check could go stale
# before the kill lands.
uitest-stop:
	@if [ -x scripts/exclusive-lock.sh ]; then \
	    ./scripts/exclusive-lock.sh acquire uitest $$$$ || exit $$?; \
	    trap "./scripts/exclusive-lock.sh release uitest $$$$" EXIT; \
	fi; \
	pkill -f 'DeviceTermUITestHarness.app/Contents/MacOS/deviceterm-uitest' >/dev/null 2>&1 || true; \
	echo "stopped deviceterm-uitest resident (if running)"

# Launch the harness through LaunchServices (`open`), never as a child of
# this shell: TCC resolves a process's grants through its responsible
# process, so a shell-spawned harness would attribute to your terminal.
# `open` hands the launch to launchd, giving the .app its own identity.
# Assembling the bundle, stopping the resident, and relaunching all run
# inside one lock span. Assembling under a separate lock would leave a
# gap for another checkout to swap the shared bundle, and this target
# would then launch that checkout's harness.
uitest-run: uitest
	@if [ ! -x scripts/uitest-bundle.sh ]; then \
	    echo "make uitest-run: scripts/uitest-bundle.sh does not exist — skipping"; \
	    exit 0; \
	fi; \
	./scripts/exclusive-lock.sh acquire uitest $$$$ || exit $$?; \
	trap "./scripts/exclusive-lock.sh release uitest $$$$" EXIT; \
	DEVICETERM_UITEST_LOCK_HELD=1 ./scripts/uitest-bundle.sh || exit $$?; \
	APP="$${DEVICETERM_UITEST_APP:-$$HOME/Applications/DeviceTermUITestHarness.app}"; \
	if [ ! -d "$$APP" ]; then \
	    echo "make uitest-run: harness bundle missing — skipping"; \
	else \
	    pkill -f 'DeviceTermUITestHarness.app/Contents/MacOS/deviceterm-uitest' >/dev/null 2>&1 || true; \
	    open "$$APP" --args serve; \
	    for _ in 1 2 3 4 5 6 7 8; do .build/debug/deviceterm-uitest ping >/dev/null 2>&1 && break; sleep 0.25; done; \
	    if ! .build/debug/deviceterm-uitest ping >/dev/null 2>&1; then \
	        echo "make uitest-run: resident did not come up (check the build/signature)" >&2; \
	        exit 1; \
	    elif .build/debug/deviceterm-uitest doctor; then \
	        echo "make uitest-run: harness ready — Screen Recording + Accessibility granted"; \
	    else \
	        ./scripts/uitest-grant.sh; \
	    fi; \
	fi

probe:
	@if [ -d Sources/CompatProbe ]; then \
	    swift run deviceterm-probe; \
	else \
	    echo "make probe: Sources/CompatProbe/ does not exist — skipping"; \
	fi

# ──────────────────────────────────────────────────────────────────────────
# Test
# ──────────────────────────────────────────────────────────────────────────

test:
	@if find Tests -name '*.swift' 2>/dev/null | head -1 | grep -q .; then \
	    swift test --no-parallel --skip CoreSimulatorLiveTests --skip DeviceLiveTests; \
	    echo "make test: live tracks skipped — run 'make test-live' / 'make test-device-live' deliberately"; \
	else \
	    echo "make test: no Tests/*.swift yet — skipping"; \
	fi
# `--no-parallel`: daemon RPC tests spin up UDS servers and PTY tests
# fork real child processes. Running them in parallel saturates fds /
# the process table on busy machines and produces flaky receive
# timeouts. The whole suite finishes in seconds either way — parallel
# isn't worth the contention.

test-int:
	@if [ -d Tests/DaemonIntegrationTests ]; then \
	    swift test --filter DaemonIntegrationTests; \
	else \
	    echo "make test-int: Tests/DaemonIntegrationTests/ does not exist — skipping"; \
	fi

test-gui: bundle
	@# Script-driven GUI smoke. The same script also runs inside
	@# `make verify`, so the default gate catches dispatch / reconcile
	@# regressions. By project tenet (no .xcodeproj, no XCTest UI) this
	@# is the *only* GUI gate — there is no XCUIApplication fallback.
	@./scripts/gui-smoke.sh debug

test-shim:
	@ran=0; \
	if [ -d Tests/ShimTests ]; then swift test --filter ShimTests; ran=1; fi; \
	if [ -d Tests/CLITests ]; then swift test --filter CLITests; ran=1; fi; \
	if [ "$$ran" -eq 0 ]; then \
	    echo "make test-shim: Tests/ShimTests + Tests/CLITests do not exist — skipping"; \
	fi

# Deliberate live-simulator track (CoreSimulatorLiveTests). These tests
# need a *booted* sim and drive real HID/AX/display I/O, or assert the
# daemon's booted-owned contract — non-hermetic and slow, so they're
# excluded from `make verify`/`make test`. This target owns a clean
# slate: it shuts down ALL simulators (including ones you're running —
# by design), boots one device, waits until it's fully up, runs the
# track, then shuts it down. Run after changing CoreSimulatorBridge or
# other private-API code.
test-live:
	@if [ -d Tests/CoreSimulatorLiveTests ]; then \
	    ./scripts/test-live.sh; \
	else \
	    echo "make test-live: Tests/CoreSimulatorLiveTests/ does not exist — skipping"; \
	fi

# Deliberate live-physical-device track (DeviceLiveTests). Needs a
# connected, unlocked, trusted iPhone/iPad with the OS CoreDevice tunnel
# held up (Xcode → Devices and Simulators, or Device Hub). Drives the
# daemon's RealDeviceBackend against real hardware: enumerate → resolve →
# frames flow → HID discovery → touch → detach. Non-hermetic, so excluded
# from `make verify`/`make test`. NEVER reboots or shuts down the device.
# Fails loudly (does not silently no-op) when no device tunnel is present.
test-device-live:
	@if [ -d Tests/DeviceLiveTests ]; then \
	    ./scripts/test-device-live.sh; \
	else \
	    echo "make test-device-live: Tests/DeviceLiveTests/ does not exist — skipping"; \
	fi

# Deliberate UI-test-harness track. Non-hermetic: needs the harness's
# TCC grants and an unlocked display, so it stays out of `make verify` /
# `make test` (which never see it — it self-skips when the harness source
# is absent). Sim-free by design; the sim/device scenarios are driven
# interactively via the deviceterm-e2e skill, not automated here.
test-uitest:
	@if [ -d Sources/DeviceTermUITest ] && [ -x scripts/test-uitest.sh ]; then \
	    ./scripts/test-uitest.sh; \
	else \
	    echo "make test-uitest: Sources/DeviceTermUITest/ absent — skipping"; \
	fi

# ──────────────────────────────────────────────────────────────────────────
# Lint + verify
# ──────────────────────────────────────────────────────────────────────────

lint:
	@if ! command -v swiftlint >/dev/null 2>&1; then \
	    echo "make lint: swiftlint not found — install via 'brew install swiftlint'"; \
	    exit 1; \
	fi; \
	if find Sources Tests -name '*.swift' -print -quit 2>/dev/null | grep -q .; then \
	    swiftlint lint --strict --quiet && echo "lint: ok"; \
	else \
	    echo "make lint: no Swift sources yet — skipping"; \
	fi

# verify is the single-command gate. Sub-checks self-skip when their backing
# code doesn't exist yet — the gate always exits 0 on a green tree, and the
# checks become meaningful as Sources/, Tests/, and scripts/ populate.
verify: lint
	@./scripts/verify.sh

# ──────────────────────────────────────────────────────────────────────────
# libghostty harness
#
# libghostty itself is the libghostty-spm SwiftPM package (GhosttyKit
# xcframework + GhosttyKitResources); SwiftPM fetches it — nothing to
# build locally. This target just runs the standalone smoke harness.
# ──────────────────────────────────────────────────────────────────────────

run-libghostty-harness:
	@if [ -d Sources/LibghosttyHarness ]; then \
	    swift run LibghosttyHarness; \
	else \
	    echo "run-libghostty-harness: Sources/LibghosttyHarness/ does not exist — skipping"; \
	fi

# ──────────────────────────────────────────────────────────────────────────
# Release
# ──────────────────────────────────────────────────────────────────────────

release:
	@if [ -x scripts/build-release.sh ]; then \
	    ./scripts/build-release.sh --dmg; \
	else \
	    echo "make release: scripts/build-release.sh not present — skipping"; \
	fi

# Publish an already-built, notarized release (local; needs a public repo
# + gh auth): refresh the Homebrew cask in the tap, generate the Sparkle
# appcast, and create the GitHub release. Run after `make release`.
publish:
	@if [ -x scripts/publish-release.sh ]; then \
	    ./scripts/publish-release.sh; \
	else \
	    echo "make publish: scripts/publish-release.sh not present — skipping"; \
	fi

# ──────────────────────────────────────────────────────────────────────────
# Setup
# ──────────────────────────────────────────────────────────────────────────

# Install the hooks path and reject hooks that are not executable or do
# not parse with Bash.
hooks:
	@git config core.hooksPath .githooks
	@for hook in .githooks/*; do \
	    [ -x "$$hook" ] || { echo "make hooks: $$hook is not executable" >&2; exit 1; }; \
	    bash -n "$$hook" || { echo "make hooks: $$hook has a syntax error" >&2; exit 1; }; \
	done
	@echo "git hooks installed (.githooks/) — all hooks executable and parse"

clean:
	@rm -rf .build
	@echo "wiped .build/"
