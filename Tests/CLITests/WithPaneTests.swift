// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// `deviceterm with-pane <ref> <cmd…>` parser surface.
//
// The runner in main.swift gathers panes.list + spawns the child
// process; those code paths need a live daemon and are exercised by
// the manual checklist. The parser logic is pure and covers:
// - Happy path (ref + cmd + args)
// - Refused without ref or cmd
// - The global --json strip is bypassed for the exec wrapper (child
//   sees its own flags literally)
// - outputMode is forced to .human for the exec wrapper (the tail's
//   --json is the child's, not deviceterm's)

// MARK: - Parser

@Test
func parseWithPaneResolvesToWithPane() {
    #expect(
        CLICommands.parse(
        ["deviceterm", "with-pane", "phn001", "bash", "-c", "echo hi"]
    )
        == .withPane(ref: "phn001", cmd: ["bash", "-c", "echo hi"])
        )
}

@Test
func parseWithPaneAcceptsSingleCmdNoArgs() {
    #expect(
        CLICommands.parse(["deviceterm", "with-pane", "phn001", "pwd"])
        == .withPane(ref: "phn001", cmd: ["pwd"])
        )
}

@Test
func parseWithPaneMissingCmdIsUsage() {
    // ref but no command, so the only thing we can do is refuse.
    guard case let .usage(message) = CLICommands.parse(
        ["deviceterm", "with-pane", "phn001"]
    ) else {
        Issue.record("expected .usage for missing cmd")
        return
    }
    #expect(message?.contains("with-pane") ?? false)
}

@Test
func parseWithPaneMissingRefAndCmdIsUsage() {
    guard case .usage = CLICommands.parse(["deviceterm", "with-pane"]) else {
        Issue.record("bare with-pane should be .usage")
        return
    }
}

// MARK: - JSON strip bypass

@Test
func parseWithPanePreservesChildJSONFlag() {
    // The child's flags are literal, even `--json`. The global
    // --json strip is skipped for with-pane so the child sees its
    // own argv unchanged.
    #expect(
        CLICommands.parse(
        ["deviceterm", "with-pane", "phn001", "myscript", "--json"]
    )
        == .withPane(ref: "phn001", cmd: ["myscript", "--json"])
        )
}

@Test
func parseWithPanePreservesChildJSONAfterArgs() {
    // Mid-args --json stays put.
    #expect(
        CLICommands.parse(
        ["deviceterm", "with-pane", "phn001", "myscript", "--json", "extra"]
    )
        == .withPane(ref: "phn001", cmd: ["myscript", "--json", "extra"])
        )
}

@Test
func parseWithPanePreservesChildJSONWhenGlobalJSONPrecedesVerb() {
    // Regression guard: when callers use the
    // global-flag style `deviceterm --json with-pane <ref> <cmd>
    // --json`, with-pane is at argv[2], not argv[1]. The strip
    // must locate the verb correctly and preserve every token
    // after it; the child's --json stays literal.
    #expect(
        CLICommands.parse(
        [
        "deviceterm",
        "--json",
        "with-pane",
        "phn001",
        "myscript",
        "--json"
        ]
        ) == .withPane(ref: "phn001", cmd: ["myscript", "--json"])
        )
}

@Test
func parseWithPanePreservesChildJSONWithMultipleGlobalFlags() {
    // Defense-in-depth: multiple --json before the verb (a buggy
    // wrapper double-stacking the flag) still doesn't reach the
    // child's argv.
    #expect(
        CLICommands.parse(
        [
        "deviceterm",
        "--json",
        "--json",
        "with-pane",
        "phn001",
        "myscript",
        "--json"
        ]
        ) == .withPane(ref: "phn001", cmd: ["myscript", "--json"])
        )
}

@Test
func outputModeForWithPaneIsAlwaysHuman() {
    // The post-verb tail is the child's argv, so `--json` after the
    // verb is the child's flag, not deviceterm's. outputMode forces
    // human so the with-pane dispatch site isn't confused.
    #expect(
        CLICommands.outputMode(
        for:
        ["deviceterm", "with-pane", "phn001", "bash", "--json"]
        ) == .human
        )
    #expect(
        CLICommands.outputMode(
        for:
        ["deviceterm", "with-pane", "phn001", "--json"]
        ) == .human
        )
}

// MARK: - Verb-position carve-out

@Test
func parseTextTreatsWithPaneAsLiteral() {
    // Regression guard: `with-pane` fires only in the verb
    // position. Downstream text input that happens to contain
    // "with-pane" stays literal.
    #expect(
        CLICommands.parse(["deviceterm", "text", "with-pane"])
        == .text(pane: nil, text: "with-pane")
        )
}

// MARK: - DeviceTermEnv target env var names are canonical

@Test
func deviceTermEnvTargetNamesAreDocumented() {
    // Pin the exact env var name so a rename can't silently break the
    // `with-pane` → `resolvePane` env fallback.
    #expect(DeviceTermEnv.targetPane == "DEVICETERM_TARGET_PANE")
}

// MARK: - mapChildExitCode (signal mapping)

@Test
func mapChildExitCodeReturnsStatusForOrderlyExit() {
    // Orderly child exit: pass through unchanged. The shell
    // convention `128 + signum` only applies to signaled
    // terminations; ordinary `exit 15` stays 15, not 143.
    #expect(
        CLICommands.mapChildExitCode(
        status: 0,
        reason: .exit
    ) == 0
        )
    #expect(
        CLICommands.mapChildExitCode(
        status: 1,
        reason: .exit
    ) == 1
        )
    #expect(
        CLICommands.mapChildExitCode(
        status: 15,
        reason: .exit
    ) == 15
        )
}

@Test
func mapChildExitCodeMapsSignalsToShellConvention() {
    // Signal-terminated: `128 + signum`. Regression guard, because a
    // naive implementation conflates SIGTERM with `exit 15`.
    #expect(
        CLICommands.mapChildExitCode(
        status: 15,
        reason: .uncaughtSignal
    ) == 143
        )  // SIGTERM
    #expect(
        CLICommands.mapChildExitCode(
        status: 2,
        reason: .uncaughtSignal
    ) == 130
        )   // SIGINT
    #expect(
        CLICommands.mapChildExitCode(
        status: 9,
        reason: .uncaughtSignal
    ) == 137
        )   // SIGKILL
}
