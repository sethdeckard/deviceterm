// SPDX-License-Identifier: GPL-3.0-or-later
//
// WelcomeSeenStore: which welcome windows have already been shown.
//
// Lives in the XDG cache directory, not in
// `~/.config/deviceterm/config`. The config file is hand-edited and
// holds preferences the user sets; this is bookkeeping the app writes,
// and mixing the two would put machine-managed lines in a file people
// keep in git. The on/off switch (`welcome-messages`) stays in config,
// because that one *is* a preference.
//
// Format is one id per line. It needs none of the config file's
// `key = value` syntax or comments, and one id per line also makes the
// documented reset easy: delete a line to re-arm that welcome.
//
// Every failure is non-fatal and degrades toward showing a welcome
// again: an unreadable file parses as "none seen" and a failed write is
// dropped, so a welcome can recur after a failed write or a cleared
// cache. Re-explaining something is a smaller harm than a crash or a
// swallowed launch.

import DaemonProtocol
import Foundation

struct WelcomeSeenStore {
    private let path: String

    init(path: String = XDGPaths.deviceTermWelcomeSeen()) {
        self.path = path
    }

    /// Parse the file body: one id per line, blank lines dropped and
    /// surrounding whitespace trimmed.
    static func parse(_ text: String) -> Set<String> {
        let ids = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(ids)
    }

    /// Render a seen set to the file body. Sorted, so rewriting an
    /// unchanged set produces an identical file and a diff stays empty.
    /// A trailing newline keeps it well-formed for line-based tools.
    static func format(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: "\n") + "\n"
    }

    /// Ids already shown. An absent or unreadable file reads as empty,
    /// so a fresh install and a corrupted cache behave the same way.
    func read() -> Set<String> {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        return Self.parse(text)
    }

    /// Replace the file with `ids`, creating the parent directory if
    /// needed. Write failures are swallowed: the cost is re-showing a
    /// welcome next launch, which does not justify surfacing an error
    /// during app startup.
    func write(_ ids: Set<String>) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        try? Self.format(ids).write(toFile: path, atomically: true, encoding: .utf8)
    }
}
