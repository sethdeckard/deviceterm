// SPDX-License-Identifier: GPL-3.0-or-later
//
// ShellCommandLine: marshal a TerminalCommand into the shapes
// libghostty's `ghostty_surface_config_s` wants.
//
// libghostty owns the PTY and `posix_spawn`s the child *through a
// shell*: `config.command` is a single command-line string the shell
// word-splits, NOT an argv array (there is no argv field in the C
// API). So an executable + args must be POSIX-quoted and joined; an
// unquoted space in the path or an arg would be split by the shell
// into separate words. Env vars, by contrast, are a `{key,value}`
// array, not `KEY=VALUE` strings.
//
// This is the one piece of the bridge with logic worth unit-testing
// in isolation (the rest needs a live Metal surface), so it's a pure
// value type with no libghostty dependency.

import TerminalSurface

enum ShellCommandLine {
    /// POSIX single-quote one argument: wrap in `'…'`, and turn any
    /// embedded `'` into the classic `'\''` escape. Safe for every
    /// byte including spaces, `$`, backticks, globs, newlines.
    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The single command-line string for `config.command`: the
    /// executable followed by each argument, every component quoted.
    static func commandString(for command: TerminalCommand) -> String {
        ([command.executable] + command.arguments)
            .map(quote)
            .joined(separator: " ")
    }

    /// Environment as ordered `(key, value)` pairs. Sorted by key so
    /// the marshaled C array is deterministic (stable tests, stable
    /// diffs); libghostty doesn't care about order.
    static func environmentPairs(
        for command: TerminalCommand
    ) -> [(key: String, value: String)] {
        command.environment
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
    }
}
