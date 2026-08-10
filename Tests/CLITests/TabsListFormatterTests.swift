// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// TabsListFormatter: the five-column row shape.
//
// Pins the tab-separated five-column contract:
//   {marker}\t{short_id}\t{name}\t{session_id}\t{label}
// agents parse this with `awk -F'\t'`; a regression on column
// count or order would break every downstream script silently.

private let alpha = TabsListEntry(
    sessionId: "11111111-1111-1111-1111-111111111111",
    label: "Alpha",
    shortId: "ab12cd",
    name: "alpha"
)

private let beta = TabsListEntry(
    sessionId: "22222222-2222-2222-2222-222222222222",
    label: nil,
    shortId: "ef34gh",
    name: nil
)

private let noShortID = TabsListEntry(
    sessionId: "33333333-3333-3333-3333-333333333333",
    label: nil,
    shortId: nil,
    name: nil
)

// MARK: - Per-row shape

@Test
func formatRowEmitsFiveTabSeparatedColumns() {
    let row = TabsListFormatter.formatRow(entry: alpha, isCurrent: false)
    let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
    #expect(columns.count == 5, "row must have exactly five columns, got \(columns.count): \(row)")
}

@Test
func formatRowMarksCurrentTabWithAsterisk() {
    let row = TabsListFormatter.formatRow(entry: alpha, isCurrent: true)
    #expect(row.hasPrefix("*\t"))
}

@Test
func formatRowMarksNonCurrentTabWithSpace() {
    // Single literal space char + tab, git-branch's convention.
    // Keeps the column count stable so awk -F'\t' sees five fields
    // on every row regardless of current-ness.
    let row = TabsListFormatter.formatRow(entry: alpha, isCurrent: false)
    #expect(row.hasPrefix(" \t"))
}

@Test
func formatRowColumnsAreInDocumentedOrder() {
    let row = TabsListFormatter.formatRow(entry: alpha, isCurrent: true)
    let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
    #expect(String(columns[0]) == "*")
    #expect(String(columns[1]) == "ab12cd")
    #expect(String(columns[2]) == "alpha")
    #expect(String(columns[3]) == "11111111-1111-1111-1111-111111111111")
    #expect(String(columns[4]) == "Alpha")
}

@Test
func formatRowEncodesNilNameAndLabelAsEmpty() {
    let row = TabsListFormatter.formatRow(entry: beta, isCurrent: false)
    let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
    #expect(columns[2].isEmpty, "nil name should emit empty column")
    #expect(columns[4].isEmpty, "nil label should emit empty column")
}

@Test
func formatRowEncodesAbsentShortIdAsQuestionMark() {
    // An older daemon may not emit `shortId`; the column has to
    // stay populated so downstream parsers see five tab-separated
    // fields.
    let row = TabsListFormatter.formatRow(entry: noShortID, isCurrent: false)
    let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
    #expect(String(columns[1]) == TabsListFormatter.missingShortIdPlaceholder)
}

// MARK: - List-level marker selection

@Test
func formatListMarksOnlyTheMatchingSession() {
    let lines = TabsListFormatter.formatList(
        entries: [alpha, beta, noShortID],
        currentSessionId: beta.sessionId
    )
    #expect(lines.count == 3)
    #expect(lines[0].hasPrefix(" \t"))
    #expect(lines[1].hasPrefix("*\t"))
    #expect(lines[2].hasPrefix(" \t"))
}

@Test
func formatListWithNoCurrentSessionMarksNothing() {
    // Out-of-tab invocation: no DEVICETERM_SESSION env, so nothing
    // gets the * marker. Every row uses the space marker.
    let lines = TabsListFormatter.formatList(
        entries: [alpha, beta],
        currentSessionId: nil
    )
    #expect(lines.allSatisfy { $0.hasPrefix(" \t") })
}

@Test
func formatListEmptyEntriesReturnsEmpty() {
    let lines = TabsListFormatter.formatList(entries: [], currentSessionId: nil)
    #expect(lines.isEmpty)
}

// MARK: - Parser

@Test
func parseTabsCurrentResolvesToTabsCurrent() {
    #expect(CLICommands.parse(["deviceterm", "tabs", "current"]) == .tabsCurrent)
}

@Test
func parseTabsBareSuggestsBothSubcommands() throws {
    let result = CLICommands.parse(["deviceterm", "tabs"])
    guard case let .usage(message) = result else {
        Issue.record("expected .usage, got \(result)")
        return
    }
    let text = try #require(message)
    #expect(text.contains("list"))
    #expect(text.contains("current"))
}

@Test
func parseTabsUnknownSubcommandSuggestsBoth() throws {
    let result = CLICommands.parse(["deviceterm", "tabs", "burn"])
    guard case let .usage(message) = result else {
        Issue.record("expected .usage, got \(result)")
        return
    }
    let text = try #require(message)
    #expect(text.contains("list"))
    #expect(text.contains("current"))
}
