// SPDX-License-Identifier: GPL-3.0-or-later

@testable import DeviceTermCLI
import Foundation
import Testing

// `--json` parser surface. Covers detection, argv strip, and the
// parser-coverage standing rule (every verb's parse continues to
// work with `--json` in any position). Pure-logic, no I/O.

// MARK: - outputMode(for:)

@Test
func outputModeDefaultsToHuman() {
    #expect(CLICommands.outputMode(for: ["deviceterm", "tap", "0.5", "0.5"]) == .human)
    #expect(CLICommands.outputMode(for: ["deviceterm"]) == .human)
    #expect(CLICommands.outputMode(for: ["deviceterm", "tabs", "list"]) == .human)
}

@Test
func outputModeDetectsJSONFlag() {
    #expect(CLICommands.outputMode(for: ["deviceterm", "tabs", "list", "--json"]) == .json)
    #expect(CLICommands.outputMode(for: ["deviceterm", "--json", "tabs", "list"]) == .json)
    #expect(CLICommands.outputMode(for: ["deviceterm", "tap", "--json", "0.5", "0.5"]) == .json)
}

@Test
func outputModeRespectsDoubleDashTerminator() {
    // `deviceterm text -- --json` types the literal "--json"; the
    // mode detector must NOT pick that up.
    #expect(
        CLICommands.outputMode(
        for:
        ["deviceterm", "text", "--", "--json"]
        ) == .human
        )
    #expect(
        CLICommands.outputMode(
        for:
        ["deviceterm", "text", "--", "hello", "--json"]
        ) == .human
        )
}

@Test
func outputModeMixesWithUdidAndDuration() {
    // --json coexists with the existing per-command flags; order
    // is irrelevant.
    #expect(
        CLICommands.outputMode(
        for: [
        "deviceterm",
        "swipe",
        "0",
        "0",
        "1",
        "1",
        "--duration",
        "250",
        "--pane",
        "W",
        "--json"
        ]
        ) == .json
        )
}

// MARK: - parse strips --json before dispatch

@Test
func parseStripsJSONFromTapDispatch() {
    // The tap parser needs exactly two positionals (x, y). `--json`
    // would otherwise be an extra positional; the strip keeps the
    // dispatch arity stable.
    #expect(
        CLICommands.parse(["deviceterm", "tap", "0.5", "0.5", "--json"])
        == .tap(pane: nil, x: 0.5, y: 0.5)
        )
    #expect(
        CLICommands.parse(["deviceterm", "tap", "--json", "0.5", "0.5"])
        == .tap(pane: nil, x: 0.5, y: 0.5)
        )
}

@Test
func parseStripsJSONFromSwipeDispatch() {
    #expect(
        CLICommands.parse(
        [
        "deviceterm",
        "swipe",
        "0",
        "0",
        "1",
        "1",
        "--duration",
        "100",
        "--json"
        ]
        ) == .swipe(
        pane: nil,
        fromX: 0,
        fromY: 0,
        toX: 1,
        toY: 1,
        durationMs: 100,
        holdMs: nil
        )
        )
}

@Test
func parseStripsJSONFromTabsListDispatch() {
    #expect(CLICommands.parse(["deviceterm", "tabs", "list", "--json"]) == .tabsList)
    #expect(CLICommands.parse(["deviceterm", "tabs", "current", "--json"]) == .tabsCurrent)
}

@Test
func parsePreservesLiteralJSONAfterDoubleDash() {
    // `text -- --json` types the literal "--json": the strip
    // respects the `--` terminator.
    #expect(
        CLICommands.parse(["deviceterm", "text", "--", "--json"])
        == .text(pane: nil, text: "--json")
        )
}

@Test
func parseStripsJSONFromCrownWithNegativeDelta() {
    // Regression guard for the crown case: `--json` must not eat
    // or confuse the negative-delta positional.
    #expect(
        CLICommands.parse(
        ["deviceterm", "crown", "-15", "--duration", "200", "--json"]
    )
        == .crown(pane: nil, delta: -15, velocity: nil, durationMs: 200)
        )
}

@Test
func parseStripsJSONFromHelpTrigger() {
    // `--help --json` still resolves to .help, since the help text is
    // human regardless (JSON help is a separate follow-up; the
    // strip just keeps the trigger from being shadowed).
    #expect(CLICommands.parse(["deviceterm", "--help", "--json"]) == .help(topic: nil))
}
