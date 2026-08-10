#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# uitest-grant.sh — guide the one-time TCC grant for the harness.
#
# macOS won't let anything grant Screen Recording / Accessibility
# programmatically (SIP-protected), so the user must toggle them once. The
# only real friction is finding the app and the right panes — so do both
# for them: reveal the bundle in Finder (to drag in) and open the two
# Privacy panes directly. Run by `make uitest-run` when a grant is missing.

set -eu

APP="${DEVICETERM_UITEST_APP:-$HOME/Applications/DeviceTermUITestHarness.app}"

echo ""
echo "───────────────────────────────────────────────────────────────"
echo " The UI-test harness needs two permissions (one time only):"
echo "   • Screen Recording"
echo "   • Accessibility"
echo ""
echo " Opening both Privacy panes and revealing the app so you can drag"
echo " it into each list, then flip the toggle on:"
echo "   $APP"
echo "───────────────────────────────────────────────────────────────"

# Reveal the bundle so it can be dragged straight into the Privacy list.
open -R "$APP" 2>/dev/null || true
# Jump to the exact panes (no hunting through System Settings).
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true

echo ""
echo " In each pane: drag DeviceTermUITestHarness.app from the Finder"
echo " window onto the list (or click +), then toggle it on."
echo " When both are on, re-run:  make uitest-run"
echo ""
