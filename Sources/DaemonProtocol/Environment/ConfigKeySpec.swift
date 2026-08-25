// SPDX-License-Identifier: GPL-3.0-or-later

/// The full description of one recognized
/// `~/.config/deviceterm/config` key: its default, its allowed values,
/// and a one-line summary of what it does.
///
/// This is the source of truth the app uses to write a self-documenting
/// config file: every key the app touches is preceded by a doc comment
/// (summary + allowed values + default or absent behavior), and every
/// recognized key the user hasn't set is written as a commented-out
/// example. The format is
/// Ghostty's `key = value` with line-leading `#` comments, not TOML,
/// so the docs are plain `#` lines.
public struct ConfigKeySpec: Sendable, Equatable {
    public let key: String
    public let defaultValue: String
    public let allowedValues: [String]
    public let summary: String
    /// What the app does when the key is absent, for keys whose
    /// `defaultValue` is a choice a *present* key selects rather than a
    /// value applied on absence (the prompt-suppression keys: absent
    /// means the prompt is shown). Nil means the default genuinely
    /// applies when the key is missing. `deviceterm dump-config` reports
    /// keys carrying this as `unset` with this text as the note, instead
    /// of claiming the documented default is effective.
    public let absentBehavior: String?

    /// The doc-comment lines (each a line-leading `#` comment, no
    /// trailing newline) that precede the key in a written config file.
    /// Keys with an `absentBehavior` document that instead of a
    /// "Default:" that would wrongly imply the value applies while the
    /// key is unset.
    public var documentationLines: [String] {
        let allowed = "Allowed: \(allowedValues.joined(separator: ", "))."
        let tail: String
        if let absentBehavior {
            tail = "# \(allowed) Unset: \(absentBehavior)."
        } else {
            tail = "# \(allowed) Default: \(defaultValue)."
        }
        return ["# \(summary)", tail]
    }

    /// A commented-out example assignment at the default value, written
    /// for recognized keys the user hasn't set so the file lists every
    /// available option.
    public var exampleLine: String {
        "# \(key) = \(defaultValue)"
    }

    public init(
        key: String,
        defaultValue: String,
        allowedValues: [String],
        summary: String,
        absentBehavior: String? = nil
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.allowedValues = allowedValues
        self.summary = summary
        self.absentBehavior = absentBehavior
    }
}
