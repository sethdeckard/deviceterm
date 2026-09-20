// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The block format of `<config home>/deviceterm/automation-programs`.
///
///     # a comment
///     program build-bridge
///       command ~/.local/bin/build-bridge --socket ~/.cache/build-bridge.sock
///       cwd ~/work
///
///     program watcher
///       command ~/bin/watch-builds
///
/// A `program <name>` line at column zero opens a block, and the indented
/// lines under it are its fields. Any indented line closes with the block it
/// follows; the next unindented line ends it. Blank lines and lines whose
/// first non-space character is `#` are skipped everywhere.
///
/// **Keys take the first whitespace-delimited token; the value is the rest of
/// the line**, with surrounding whitespace removed. A value's internal
/// spacing, quotes, and `~` survive untouched and the shell is what
/// interprets them, the same way `deviceterm tab open --command '<cmd>'`
/// already works. A name may contain spaces for the same reason.
///
/// **Only three things make a block unusable**: no name, no command, or a
/// name an earlier block already took. Each is an `AutomationProgramDefect`
/// and skips that block alone.
///
/// **Everything else this version does not understand is ignored, never an
/// error.** An unrecognized field, an unrecognized line at column zero, and
/// an indented line before any block all leave no trace. That is what lets a
/// file written for a newer deviceterm still run here, and it is the same
/// rule `LocationsFileParser` follows for the sibling locations file.
enum AutomationProgramsFileParser {
    /// A block being read: its `program` line, plus whichever fields have
    /// been seen so far. Every field is optional here and resolved to its
    /// default only once the block closes, so "absent" and "set to the
    /// default" stay distinguishable while parsing.
    private struct Block {
        let name: String
        let line: Int
        var command: String?
        var cwd: String?
    }

    /// The column-zero keyword that opens a block.
    static let blockKeyword = "program"

    /// Parse every block in `lines`, in file order.
    ///
    /// `directory` is the folder holding the file, used to resolve a relative
    /// `cwd`. Resolution happens here because this is the last place that
    /// knows where the file lived.
    static func parse(
        lines: [String],
        relativeTo directory: String
    ) -> (entries: [AutomationProgramEntry], defects: [AutomationProgramDefect]) {
        var entries: [AutomationProgramEntry] = []
        var defects: [AutomationProgramDefect] = []
        var taken: Set<String> = []
        var open: Block?

        func closeBlock() {
            guard let block = open else { return }
            open = nil
            guard !taken.contains(block.name) else {
                defects.append(
                    AutomationProgramDefect(
                        name: block.name,
                        line: block.line,
                        reason: .duplicateName
                    )
                )
                return
            }
            guard let entry = entry(from: block, relativeTo: directory) else {
                defects.append(
                    AutomationProgramDefect(
                        name: block.name,
                        line: block.line,
                        reason: .missingCommand
                    )
                )
                return
            }
            taken.insert(block.name)
            entries.append(entry)
        }

        for (index, raw) in lines.enumerated() {
            // Newlines as well as spaces and tabs: a CRLF file leaves a `\r`
            // on every line once the file is split on `\n`, and it would
            // otherwise glue an invisible character to the end of every value.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if raw.first == " " || raw.first == "\t" {
                guard open != nil else { continue }
                let (key, value) = field(from: trimmed)
                switch key {
                case "command":
                    open?.command = value

                case "cwd":
                    open?.cwd = value.isEmpty ? nil : value

                default:
                    continue
                }
                continue
            }

            closeBlock()
            let (key, value) = field(from: trimmed)
            guard key == blockKeyword else { continue }
            guard !value.isEmpty else {
                defects.append(
                    AutomationProgramDefect(name: nil, line: index + 1, reason: .missingName)
                )
                continue
            }
            open = Block(name: value, line: index + 1)
        }
        closeBlock()
        return (entries, defects)
    }

    /// A finished block as an entry, or nil when it carries no command.
    ///
    /// The default lands here: an absent `cwd` is the home directory.
    private static func entry(
        from block: Block,
        relativeTo directory: String
    ) -> AutomationProgramEntry? {
        guard let command = block.command, !command.isEmpty else { return nil }
        // Shared with the locations file rather than restated: one rule for
        // how deviceterm's hand-editable config files read a path, so `~` and
        // a relative path cannot come to mean different things in two of them.
        let cwd = block.cwd.map { LocationsFileParser.resolve(path: $0, relativeTo: directory) }
        return AutomationProgramEntry(
            name: block.name,
            command: [command],
            cwd: cwd ?? NSHomeDirectory()
        )
    }

    /// Split a trimmed line into its leading token and the rest.
    private static func field(from trimmed: String) -> (key: String, value: String) {
        guard let end = trimmed.firstIndex(where: \.isWhitespace) else { return (trimmed, "") }
        return (
            String(trimmed[..<end]),
            trimmed[end...].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
