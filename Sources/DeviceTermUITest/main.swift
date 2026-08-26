// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// deviceterm-uitest: out-of-process UI-test instrument for deviceterm.
//
// A dedicated, dev/test-only helper that holds the Screen Recording and
// Accessibility TCC grants so deviceterm.app never has to. An agent
// running inside a deviceterm tab drives the app through the `deviceterm`
// CLI, then asks this harness (over its own private UDS socket) to
// screenshot the window, dump its AppKit AX tree, or post a GUI-only
// gesture: the perception + drive half of the end-to-end loop. Runs
// resident (`serve`) or as a one-shot client (every other verb).
// Dev/test-only: never bundled into the release DMG.

UITestMain.run(args: Array(CommandLine.arguments.dropFirst()))
