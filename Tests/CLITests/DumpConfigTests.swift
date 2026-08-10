// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// `deviceterm dump-config` parser + formatter + report builder. All
// three are pure-logic; the runner in main.swift reads the file
// from disk and hands the text in.

// MARK: - Parser

@Test
func parseDumpConfigResolvesToDumpConfig() {
    #expect(CLICommands.parse(["deviceterm", "dump-config"]) == .dumpConfig)
}

@Test
func parseDumpConfigAcceptsJSONFlag() {
    #expect(
        CLICommands.parse(
        ["deviceterm", "dump-config", "--json"]
    ) == .dumpConfig
        )
}

@Test
func parseTextTreatsDumpConfigAsLiteral() {
    #expect(
        CLICommands.parse(["deviceterm", "text", "dump-config"])
        == .text(pane: nil, text: "dump-config")
        )
}

// MARK: - parseFile

@Test
func parseFileEmptyTextReturnsEmpty() {
    #expect(DumpConfig.parseFile("").isEmpty)
}

@Test
func parseFileSimpleKeyValue() {
    let text = "tab-close-default = shutdown\n"
    let parsed = DumpConfig.parseFile(text)
    #expect(parsed == ["tab-close-default": "shutdown"])
}

@Test
func parseFileMultipleKeys() {
    let text = """
        tab-close-default = shutdown
        quit-with-sims-default = ask
        """
    let parsed = DumpConfig.parseFile(text)
    #expect(parsed["tab-close-default"] == "shutdown")
    #expect(parsed["quit-with-sims-default"] == "ask")
}

@Test
func parseFileIgnoresComments() {
    let text = """
        # full-line comment
        tab-close-default = shutdown
        # another comment
        """
    let parsed = DumpConfig.parseFile(text)
    #expect(parsed.count == 1)
    #expect(parsed["tab-close-default"] == "shutdown")
}

@Test
func parseFileMatchesAppConfigFileInlineCommentBehavior() {
    // Regression guard: the App-side ConfigFile
    // does NOT strip inline `# comments`; `value # note` is the
    // full value the GUI sees. dump-config has to match exactly
    // so it reports what the GUI honors, not a synthesized
    // "ideal" parse. A user with `key = shutdown # note` in
    // their file has a typo the dump-config report should
    // surface honestly.
    let text = "tab-close-default = shutdown # the standard\n"
    let parsed = DumpConfig.parseFile(text)
    #expect(parsed["tab-close-default"] == "shutdown # the standard")
}

@Test
func parseFileSkipsBlankLines() {
    let text = """

        tab-close-default = shutdown

        quit-with-sims-default = ask

        """
    let parsed = DumpConfig.parseFile(text)
    #expect(parsed.count == 2)
}

@Test
func parseFileTolerateLooseWhitespace() {
    let text = "  tab-close-default   =   shutdown  \n"
    let parsed = DumpConfig.parseFile(text)
    #expect(parsed["tab-close-default"] == "shutdown")
}

@Test
func parseFileKeepsFirstOccurrenceForRepeatedKey() {
    // Regression guard: the App-side ConfigFile
    // `value(forKey:)` returns the FIRST matching line; dump-
    // config has to mirror that so it doesn't show a value the
    // GUI never honors. Subsequent occurrences are ignored.
    let text = """
        tab-close-default = first-value
        tab-close-default = second-value
        tab-close-default = third-value
        """
    let parsed = DumpConfig.parseFile(text)
    #expect(parsed["tab-close-default"] == "first-value")
}

@Test
func parseFileSkipsMalformedLines() {
    let text = """
        tab-close-default = shutdown
        this line has no equals sign
        quit-with-sims-default = ask
        """
    let parsed = DumpConfig.parseFile(text)
    #expect(parsed.count == 2)
    #expect(parsed["tab-close-default"] == "shutdown")
    #expect(parsed["quit-with-sims-default"] == "ask")
}

// MARK: - buildReport

@Test
func reportEmitsAnEntryForEveryKnownKey() {
    let report = DumpConfig.buildReport(fileEntries: [:])
    let keys = Set(report.entries.map(\.key))
    #expect(keys == Set(DeviceTermConfigDefaults.values.keys))
    // With an empty file, keys whose default genuinely applies on
    // absence report .default; the prompt-suppression keys report
    // .unset instead (absent means the prompt is shown).
    for entry in report.entries {
        let spec = DeviceTermConfigDefaults.spec(for: entry.key)
        if spec?.absentBehavior != nil {
            #expect(entry.source == .unset, "\(entry.key) should be unset")
        } else {
            #expect(entry.source == .default, "\(entry.key) should be default")
        }
    }
}

@Test("absent prompt keys report unset with a note", arguments: [
    ("tab-close-default", "Close Tab prompt"),
    ("quit-with-sims-default", "Quit prompt")
])
func reportMarksAbsentPromptKeyUnset(key: String, fragment: String) throws {
    let report = DumpConfig.buildReport(fileEntries: [:])
    let entry = try #require(report.entries.first { $0.key == key })
    #expect(entry.source == .unset)
    #expect(entry.value.isEmpty)
    #expect(entry.note?.contains(fragment) ?? false)
}

@Test
func reportOverridesDefaultsWithFileEntries() throws {
    let report = DumpConfig.buildReport(
        fileEntries: ["tab-close-default": "shutdown"]
    )
    let tabEntry = try #require(
        report.entries.first { $0.key == "tab-close-default" }
    )
    #expect(tabEntry.value == "shutdown")
    #expect(tabEntry.source == .file)
    #expect(tabEntry.note == nil)
    // The other prompt key stays unset (absent means prompt).
    let quitEntry = try #require(
        report.entries.first { $0.key == "quit-with-sims-default" }
    )
    #expect(quitEntry.source == .unset)
    // A non-prompt key still shows its applied default.
    let updateEntry = try #require(
        report.entries.first { $0.key == "auto-update" }
    )
    #expect(updateEntry.source == .default)
    #expect(updateEntry.value == "check")
}

@Test
func reportEntriesAreSortedByKey() {
    let report = DumpConfig.buildReport(fileEntries: [:])
    let keys = report.entries.map(\.key)
    #expect(keys == keys.sorted())
}

@Test
func reportWarnsOnUnrecognizedFileKeys() {
    let report = DumpConfig.buildReport(
        fileEntries: [
            "typo-here": "something",
            "tab-close-default": "shutdown"
        ]
    )
    #expect(report.warnings.count == 1)
    #expect(report.warnings.first?.contains("typo-here") ?? false)
}

@Test
func reportWarningsAreSorted() throws {
    let report = DumpConfig.buildReport(
        fileEntries: ["zzz-typo": "x", "aaa-typo": "y"]
    )
    let aIdx = try #require(report.warnings.firstIndex { $0.contains("aaa-typo") })
    let zIdx = try #require(report.warnings.firstIndex { $0.contains("zzz-typo") })
    #expect(aIdx < zIdx)
}

// MARK: - Human formatter

@Test
func formatHumanCarriesHeaderAndSeparator() {
    let report = DumpConfig.buildReport(fileEntries: [:])
    let output = DumpConfig.formatHuman(report)
    #expect(output.contains("KEY"))
    #expect(output.contains("VALUE"))
    #expect(output.contains("SOURCE"))
}

@Test
func formatHumanRendersUnsetValueAndNote() throws {
    let report = DumpConfig.buildReport(fileEntries: [:])
    let output = DumpConfig.formatHuman(report)
    let tabRow = try #require(
        output.split(separator: "\n").first { $0.hasPrefix("tab-close-default") }
    )
    #expect(tabRow.contains("-"))
    #expect(tabRow.contains("unset"))
    #expect(output.contains("note: tab-close-default is unset:"))
}

@Test
func formatHumanRendersWarningsWhenPresent() {
    let report = DumpConfig.buildReport(
        fileEntries: ["typo-here": "x"]
    )
    let output = DumpConfig.formatHuman(report)
    #expect(output.contains("warning"))
    #expect(output.contains("typo-here"))
}

// MARK: - JSON formatter

@Test
func reportJSONEncodesEntriesAndWarnings() throws {
    let report = DumpConfig.Report(
        entries: [
            DumpConfig.Entry(
                key: "auto-update",
                value: "check",
                source: .default
            ),
            DumpConfig.Entry(
                key: "tab-close-default",
                value: "shutdown",
                source: .file
            )
        ],
        warnings: [
            "unknown config key: junk"
        ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = try #require(
        String(
        data: try encoder.encode(report),
        encoding: .utf8
    )
        )
    let expected = #"{"entries":[{"key":"auto-update","source":"default","#
        + #""value":"check"},{"key":"tab-close-default","source":"file","#
        + #""value":"shutdown"}],"warnings":["unknown config key: junk"]}"#
    #expect(json == expected)
}

@Test
func reportJSONEncodesUnsetEntryWithNote() throws {
    // The `note` field appears only on unset entries (nil is omitted,
    // keeping the shape additive for existing consumers) and `value`
    // is empty rather than echoing a default the app won't apply.
    let report = DumpConfig.Report(
        entries: [
            DumpConfig.Entry(
                key: "tab-close-default",
                value: "",
                source: .unset,
                note: "the prompt is shown"
            )
        ],
        warnings: []
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = try #require(
        String(
        data: try encoder.encode(report),
        encoding: .utf8
    )
        )
    let expected = #"{"entries":[{"key":"tab-close-default","#
        + #""note":"the prompt is shown","source":"unset","value":""}],"#
        + #""warnings":[]}"#
    #expect(json == expected)
}
