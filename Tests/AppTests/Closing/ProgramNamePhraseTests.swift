// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

// What the program close prompt calls the programs it is about to stop.
// Testable without a window server, unlike the alert that renders it.

@Test("program name phrasing", arguments: [
    ([], ""),
    (["clock"], "clock"),
    (["clock", "watcher"], "clock and watcher"),
    (["clock", "watcher", "bridge"], "clock, watcher and bridge")
])
func phrasesProgramNames(names: [String], expected: String) {
    #expect(ProgramNamePhrase.list(names) == expected)
}
