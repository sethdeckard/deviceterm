// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// AutomationProgramsFileParserTests: the block grammar of the
// automation-programs file.
//
// Two rules carry the most weight. Only three conditions make a block
// unusable (no name, no command, a duplicate name), and each skips that
// block alone rather than the file. Everything else this version does not
// understand is ignored rather than rejected, which is what lets a file
// written for a newer deviceterm still run here.

/// A base directory a relative `cwd` resolves against.
private let base = "/config"

private func parse(
    _ lines: [String]
) -> (entries: [AutomationProgramEntry], defects: [AutomationProgramDefect]) {
    AutomationProgramsFileParser.parse(lines: lines, relativeTo: base)
}

private func home(_ component: String) -> String {
    (NSHomeDirectory() as NSString).appendingPathComponent(component)
}

// MARK: - Reading blocks

@Test("a full block parses every field")
func parsesFullBlock() {
    let parsed = parse([
        "program build-bridge",
        "  command ~/.local/bin/build-bridge --socket ~/.cache/bb.sock",
        "  cwd /Users/someone/work",
        "  restart false"
    ])
    #expect(parsed.defects.isEmpty)
    #expect(
        parsed.entries == [
            AutomationProgramEntry(
                name: "build-bridge",
                command: ["~/.local/bin/build-bridge --socket ~/.cache/bb.sock"],
                cwd: "/Users/someone/work",
                restart: false
            )
        ]
    )
}

@Test("blocks come back in file order")
func parsesInFileOrder() {
    let parsed = parse([
        "program first",
        "  command a",
        "program second",
        "  command b",
        "program third",
        "  command c"
    ])
    #expect(parsed.entries.map(\.name) == ["first", "second", "third"])
}

@Test("an absent cwd is the home directory and an absent restart is true")
func appliesDefaults() {
    let parsed = parse(["program watcher", "  command ~/bin/watch"])
    #expect(parsed.entries.first?.cwd == NSHomeDirectory())
    #expect(parsed.entries.first?.restart == true)
}

@Test("restart reads case-insensitively", arguments: [("TRUE", true), ("False", false)])
func readsRestartCaseInsensitively(value: String, expected: Bool) {
    let parsed = parse(["program p", "  command run", "  restart \(value)"])
    #expect(parsed.entries.first?.restart == expected)
}

/// An unreadable value is ignored rather than guessed at, the same way an
/// unrecognized field is, so a file written for a newer deviceterm still runs.
@Test("an unreadable restart value is ignored", arguments: ["yes", "1", "on", ""])
func ignoresUnreadableRestart(value: String) {
    let parsed = parse(["program p", "  command run", "  restart \(value)"])
    #expect(parsed.defects.isEmpty)
    #expect(parsed.entries.first?.restart == true)
}

@Test("an unreadable restart does not clear a value already read")
func unreadableRestartKeepsEarlierValue() {
    let parsed = parse(["program p", "  command run", "  restart false", "  restart maybe"])
    #expect(parsed.entries.first?.restart == false)
}

@Test("a command keeps its own spacing, quoting, and tilde verbatim")
func preservesCommandText() {
    let command = #"sh -c 'cd ~/w && ./run  --flag="a b"'"#
    let parsed = parse(["program p", "  command \(command)"])
    #expect(parsed.entries.first?.command == [command])
}

@Test("a name runs to the end of the line and may contain spaces")
func parsesMultiWordName() {
    let parsed = parse(["program my long name", "  command x"])
    #expect(parsed.entries.first?.name == "my long name")
}

@Test("comments, blank lines, and surrounding whitespace are ignored")
func skipsCommentsAndBlanks() {
    let parsed = parse([
        "# automation programs",
        "",
        "program p   ",
        "   # a comment inside the block",
        "",
        "  command   run me   "
    ])
    #expect(parsed.defects.isEmpty)
    #expect(parsed.entries.first?.name == "p")
    #expect(parsed.entries.first?.command == ["run me"])
}

@Test("an empty file yields nothing at all")
func parsesEmpty() {
    let parsed = parse([])
    #expect(parsed.entries.isEmpty)
    #expect(parsed.defects.isEmpty)
}

@Test("a comments-only file yields nothing at all")
func parsesCommentsOnly() {
    let parsed = parse(["# nothing here", "", "   "])
    #expect(parsed.entries.isEmpty)
    #expect(parsed.defects.isEmpty)
}

// MARK: - Indentation

@Test("tabs indent a field the same as spaces")
func acceptsTabIndent() {
    let parsed = parse(["program p", "\tcommand run"])
    #expect(parsed.entries.first?.command == ["run"])
}

/// A CRLF file leaves a `\r` on every line once the file is split on
/// `\n`. Without trimming it, it would glue an invisible character to the
/// end of every value.
@Test("a CRLF file parses with no stray carriage returns")
func toleratesCRLF() {
    let parsed = parse(["program p\r", "  command run\r", "  cwd /var/tmp\r"])
    #expect(parsed.entries.first?.name == "p")
    #expect(parsed.entries.first?.command == ["run"])
    #expect(parsed.entries.first?.cwd == "/var/tmp")
}

// MARK: - Defects

@Test("a block with no command is a defect and is skipped")
func reportsMissingCommand() {
    let parsed = parse(["program p", "  cwd /tmp", "program q", "  command run"])
    #expect(parsed.entries.map(\.name) == ["q"])
    #expect(
        parsed.defects == [
            AutomationProgramDefect(name: "p", line: 1, reason: .missingCommand)
        ]
    )
}

@Test("an empty command value is a defect, not an empty command")
func reportsEmptyCommand() {
    let parsed = parse(["program p", "  command   "])
    #expect(parsed.entries.isEmpty)
    #expect(parsed.defects.first?.reason == .missingCommand)
}

@Test("program with no name is a defect")
func reportsMissingName() {
    let parsed = parse(["program", "  command run"])
    #expect(parsed.entries.isEmpty)
    #expect(
        parsed.defects == [
            AutomationProgramDefect(name: nil, line: 1, reason: .missingName)
        ]
    )
}

/// File order decides, so the block a reader meets first is the one that
/// runs. Re-ordering the file is how the user changes their mind.
@Test("a duplicate name keeps the first block and reports the second")
func reportsDuplicateName() {
    let parsed = parse([
        "program p",
        "  command first",
        "program p",
        "  command second"
    ])
    #expect(parsed.entries.map(\.command) == [["first"]])
    #expect(
        parsed.defects == [
            AutomationProgramDefect(name: "p", line: 3, reason: .duplicateName)
        ]
    )
}

/// The defect names the block's own `program` line rather than whichever
/// field was wrong, so an editor jumps to the block.
@Test("a defect is reported against the block's program line")
func reportsBlockLine() {
    let parsed = parse(["", "# comment", "program p", "  cwd /tmp"])
    #expect(parsed.defects.first?.line == 3)
}

@Test("one defective block does not stop the others")
func defectiveBlockIsIsolated() {
    let parsed = parse([
        "program good-one",
        "  command a",
        "program broken",
        "  cwd /tmp",
        "program good-two",
        "  command b"
    ])
    #expect(parsed.entries.map(\.name) == ["good-one", "good-two"])
    #expect(parsed.defects.map(\.reason) == [.missingCommand])
}

// MARK: - Forward compatibility

@Test("an unrecognized field is ignored, not a defect")
func ignoresUnknownField() {
    let parsed = parse(["program p", "  command run", "  nice-level 5"])
    #expect(parsed.defects.isEmpty)
    #expect(parsed.entries.first?.command == ["run"])
}

@Test("an unrecognized line at column zero is ignored, not a defect")
func ignoresUnknownTopLevelLine() {
    let parsed = parse(["service q", "program p", "  command run"])
    #expect(parsed.defects.isEmpty)
    #expect(parsed.entries.map(\.name) == ["p"])
}

@Test("an indented line before any block is ignored")
func ignoresOrphanField() {
    let parsed = parse(["  command stray", "program p", "  command run"])
    #expect(parsed.defects.isEmpty)
    #expect(parsed.entries.first?.command == ["run"])
}

// MARK: - cwd resolution

@Test("a tilde cwd expands")
func expandsTildeCwd() {
    let parsed = parse(["program p", "  command run", "  cwd ~/work"])
    #expect(parsed.entries.first?.cwd == home("work"))
}

/// The same rule the locations file uses, so `~` and a relative path
/// cannot come to mean different things in two config files.
@Test("a relative cwd resolves against the file's own directory")
func resolvesRelativeCwd() {
    let parsed = parse(["program p", "  command run", "  cwd work/project"])
    #expect(parsed.entries.first?.cwd == "/config/work/project")
}

@Test("an absolute cwd is kept")
func keepsAbsoluteCwd() {
    let parsed = parse(["program p", "  command run", "  cwd /var/tmp"])
    #expect(parsed.entries.first?.cwd == "/var/tmp")
}
