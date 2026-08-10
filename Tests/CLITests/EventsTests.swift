// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// `deviceterm events` parser surface.
//
// The runner in main.swift opens a long-running UDS connection and
// loops printing event frames; that path needs a live daemon and is
// exercised by the manual checklist (`Tests/Manual/events.md`). The
// parser tests below pin the verb-position dispatch + the standing
// rule that all CLI parser surface is tested.

@Test
func parseEventsResolvesToEvents() {
    #expect(CLICommands.parse(["deviceterm", "events"]) == .events)
}

@Test
func parseEventsTolerateTrailingArgs() {
    // Forgiving: trailing args don't change the command (the stream
    // is the stream; nothing to parameterize).
    #expect(CLICommands.parse(["deviceterm", "events", "extra"]) == .events)
}

@Test
func parseEventsAcceptsJSONFlag() {
    // The CLI strips --json globally; the events stream is always
    // JSON (no human format) so the flag is a no-op but the strip
    // keeps the verb from being shadowed.
    #expect(CLICommands.parse(["deviceterm", "events", "--json"]) == .events)
}

@Test
func parseTextTreatsEventsAsLiteral() {
    // Verb-position carve-out: `events` fires only at argv[1].
    // Downstream text input that happens to contain "events" stays
    // literal.
    #expect(
        CLICommands.parse(["deviceterm", "text", "events"])
        == .text(pane: nil, text: "events")
        )
}

@Test
func parseDoesNotAllowEventsAfterWithPane() {
    // The exec wrapper's tail is the child's argv, so `events` there is
    // literal, not a deviceterm verb.
    #expect(
        CLICommands.parse(
        ["deviceterm", "with-pane", "phn001", "events"]
    )
        == .withPane(ref: "phn001", cmd: ["events"])
        )
}
