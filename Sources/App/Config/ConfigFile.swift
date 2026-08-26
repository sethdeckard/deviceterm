// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// A comment-preserving reader/writer for
/// `~/.config/deviceterm/config`.
///
/// `ConfigFile` supplies syntax handling, not cross-domain semantics or
/// precedence. Production writes target DeviceTerm's config; the limited
/// `GhosttyThemeColors` reader also uses this parser against a Ghostty
/// config path so app chrome can inherit selected palette values. The two
/// consumers recognize disjoint keys and do not override one another.
///
/// The file is held as an ordered list of raw lines. Reading parses
/// Ghostty-style `key = value` with line-leading `#` comments (the
/// shared Ghostty format, not TOML). Writing rewrites only the target
/// key's line in place; every other logical line (comments, blanks,
/// unknown keys) is preserved, so a user's hand-edited config survives a
/// prefs write except the one changed line. `save()` writes atomically
/// and ensures a trailing newline.
///
/// When the app *appends* a recognized key (one not yet in the file) it
/// writes a doc comment above it (summary + allowed values + default),
/// and `seedDocumentedExamples()` appends every other recognized key as
/// a commented-out example. The result is a self-documenting file that
/// lists every available option, sourced from `DeviceTermConfigDefaults`.
final class ConfigFile {
    static let defaultPath = XDGPaths.deviceTermConfig()

    private let path: String
    private var lines: [String]

    init(path: String = ConfigFile.defaultPath) {
        self.path = path
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            // Keep the original line split; don't synthesize a trailing
            // empty element for a final newline (we re-add it on save).
            var split = text.components(separatedBy: "\n")
            if split.last?.isEmpty == true { split.removeLast() }
            self.lines = split
        } else {
            self.lines = []
        }
    }

    /// Parse one line into `(key, value)`, or nil for blank/comment/
    /// non-`key = value` lines. Leading whitespace is allowed; a `#`
    /// as the first non-space char is a comment.
    private static func parse(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
        guard let equalIndex = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equalIndex].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: equalIndex)...]
            .trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return nil }
        return (key, value)
    }

    /// The value for `key`, or nil if no non-comment `key = value`
    /// line exists.
    func value(forKey key: String) -> String? {
        for line in lines {
            guard let (lineKey, lineValue) = Self.parse(line) else { continue }
            if lineKey == key { return lineValue }
        }
        return nil
    }

    /// Set `key` to `value`, replacing the existing key line in place
    /// or appending a new `key = value` line. All other lines are
    /// untouched. When appending a *recognized* key, a doc comment
    /// (summary + allowed values + default) is written above it.
    func setValue(_ value: String, forKey key: String) {
        let rendered = "\(key) = \(value)"
        for index in lines.indices {
            if let (lineKey, _) = Self.parse(lines[index]), lineKey == key {
                lines[index] = rendered
                return
            }
        }
        // New key: precede it with its documentation when we know it.
        if let spec = DeviceTermConfigDefaults.spec(for: key) {
            appendBlankIfNeeded()
            lines.append(contentsOf: spec.documentationLines)
        }
        lines.append(rendered)
    }

    /// Append a commented-out, documented example for every recognized
    /// key not already present in the file, active or as a `# key =`
    /// example, so a written config lists every available option.
    /// Idempotent: a second call adds nothing.
    func seedDocumentedExamples() {
        for spec in DeviceTermConfigDefaults.specs where !hasEntry(for: spec.key) {
            appendBlankIfNeeded()
            lines.append(contentsOf: spec.documentationLines)
            lines.append(spec.exampleLine)
        }
    }

    /// Whether `key` already appears, either as an active `key = value`
    /// line or as a commented-out `# key = value` example.
    private func hasEntry(for key: String) -> Bool {
        for line in lines {
            if let (lineKey, _) = Self.parse(line), lineKey == key {
                return true
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let equalIndex = body.firstIndex(of: "=") else { continue }
            if body[..<equalIndex].trimmingCharacters(in: .whitespaces) == key {
                return true
            }
        }
        return false
    }

    /// Append a blank separator line unless the file is empty or
    /// already ends in one, so documented blocks don't run together.
    private func appendBlankIfNeeded() {
        if let last = lines.last, !last.isEmpty {
            lines.append("")
        }
    }

    /// Write back atomically, creating the parent dir if needed. A
    /// single trailing newline is ensured.
    func save() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
