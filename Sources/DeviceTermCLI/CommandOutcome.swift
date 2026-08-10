// SPDX-License-Identifier: GPL-3.0-or-later
//
// The result of running one CLI command: the exact stdout bytes, an
// optional stderr message, and a process exit code. Handlers build and
// return this instead of writing to stdout/stderr and calling `exit`
// themselves, so the dispatch logic is pure and testable; a single thin
// driver in `main.swift` renders the outcome and terminates.
//
// `stdout` is raw bytes (already newline-terminated where the human /
// JSON format calls for it). `stderr`, when present, is the message body
// only. The driver adds the `deviceterm:` prefix and trailing newline.

import Foundation

struct CommandOutcome: Equatable {
    /// Success with no output.
    static let ok = CommandOutcome()

    var stdout: Data
    var stderr: String?
    var exitCode: Int32

    init(stdout: Data = Data(), stderr: String? = nil, exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    /// Success emitting `bytes` verbatim to stdout.
    static func stdout(_ bytes: Data) -> CommandOutcome {
        CommandOutcome(stdout: bytes)
    }

    /// Success emitting `string` to stdout verbatim (no added newline).
    static func stdout(_ string: String) -> CommandOutcome {
        CommandOutcome(stdout: Data(string.utf8))
    }

    /// Success emitting one newline-terminated line per element, the
    /// shape a `for line in … { print(line) }` loop produced. An empty
    /// list yields empty stdout (no output at all), matching a loop that
    /// never ran.
    static func lines(_ lines: [String]) -> CommandOutcome {
        guard !lines.isEmpty else { return CommandOutcome() }
        return CommandOutcome(stdout: Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    /// A domain failure: `message` (no `deviceterm:` prefix) to stderr and
    /// the given exit code (1 by default).
    static func failure(_ message: String, exitCode: Int32 = 1) -> CommandOutcome {
        CommandOutcome(stderr: message, exitCode: exitCode)
    }
}
