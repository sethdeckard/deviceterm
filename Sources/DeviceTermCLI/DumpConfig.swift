// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// `deviceterm dump-config`.
///
/// Reports the effective value for every recognized deviceterm config
/// key, annotated with the source layer (built-in default vs. user
/// file override). Keys whose documented default is only the choice a
/// present key selects (the prompt-suppression keys) report `unset`
/// with an explanatory note when absent, because no default applies:
/// the app shows the prompt. Warnings call out file entries with
/// unrecognized keys so a typo in `~/.config/deviceterm/config`
/// surfaces explicitly.
///
/// Pure parser + report; the runner in main.swift reads the file
/// from disk and hands the raw text in. Each piece is testable
/// without I/O. This covers the deviceterm overrides path that the
/// architecture-checks gate documents; the Ghostty presentation layer
/// is not parsed here.
public enum DumpConfig {
    public enum Source: String, Sendable, Codable, Equatable {
        case `default`
        case file
        /// The key is absent and no default applies (the app shows the
        /// prompt); `value` is empty and `note` explains the behavior.
        case unset
    }

    public struct Entry: Encodable, Sendable, Equatable {
        public let key: String
        public let value: String
        public let source: Source
        /// Present only on `.unset` entries: what the app does while
        /// the key is absent. Omitted from JSON when nil.
        public let note: String?

        public init(
            key: String,
            value: String,
            source: Source,
            note: String? = nil
        ) {
            self.key = key
            self.value = value
            self.source = source
            self.note = note
        }
    }

    public struct Report: Encodable, Sendable, Equatable {
        public let entries: [Entry]
        public let warnings: [String]

        public init(entries: [Entry], warnings: [String]) {
            self.entries = entries
            self.warnings = warnings
        }
    }

    /// Parse the `~/.config/deviceterm/config` text. Mirrors the App-
    /// side `ConfigFile.parse(_:)` + `value(forKey:)` semantics
    /// exactly so a dump-config report reflects what the GUI
    /// actually honors, with no parser divergence:
    ///   - Comments are line-leading only. `# foo` skips; a `#`
    ///     mid-line is part of the value (so `key = shutdown #
    ///     note` reports the value as `shutdown # note`, matching
    ///     what `value(forKey:)` sees, and surfacing the user's
    ///     mistake honestly).
    ///   - First-occurrence-wins for repeated keys.
    ///     `value(forKey:)` returns the first matching line; the
    ///     map mirrors that so dump-config doesn't show a value
    ///     the GUI never honors.
    public static func parseFile(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let equalsIdx = trimmed.firstIndex(of: "=") else {
                // Malformed line: silently skip; ConfigFile does
                // the same. Surfacing as a warning is a future
                // refinement.
                continue
            }
            let key = trimmed[..<equalsIdx]
                .trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equalsIdx)...]
                .trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            // First-occurrence wins, matching the App-side
            // ConfigFile.value(forKey:) which returns the first
            // matching line. Subsequent occurrences are ignored so
            // dump-config's `current value` lines up with what the
            // GUI reads.
            if result[key] == nil {
                result[key] = String(value)
            }
        }
        return result
    }

    /// Build the report given the file's parsed key/value map. The
    /// runner reads the file via FileManager; this function is pure.
    /// Entries are sorted by key for stable output. Warnings are
    /// emitted for file entries whose key isn't recognized.
    public static func buildReport(fileEntries: [String: String]) -> Report {
        var entries: [Entry] = []
        for key in DeviceTermConfigDefaults.values.keys.sorted() {
            if let override = fileEntries[key] {
                entries.append(Entry(key: key, value: override, source: .file))
            } else if let absent = DeviceTermConfigDefaults.spec(for: key)?.absentBehavior {
                // No default applies on absence; report that honestly
                // rather than claiming the documented value is effective.
                entries.append(Entry(key: key, value: "", source: .unset, note: absent))
            } else {
                let defaultValue = DeviceTermConfigDefaults.values[key] ?? ""
                entries.append(Entry(key: key, value: defaultValue, source: .default))
            }
        }
        let unknown = fileEntries.keys
            .filter { !DeviceTermConfigDefaults.isKnown($0) }
            .sorted()
        let warnings = unknown.map {
            "unknown config key: \($0)"
        }
        return Report(entries: entries, warnings: warnings)
    }

    /// Render the report in human-readable column form. Stable
    /// layout: KEY (left-aligned, padded) + VALUE + SOURCE. Unset
    /// entries show `-` in the VALUE column; their notes follow the
    /// table so the prompt-on-absence behavior is stated, not implied.
    public static func formatHuman(_ report: Report) -> String {
        let keyWidth = max(
            report.entries.map(\.key.count).max() ?? 0,
            "KEY".count
        )
        let valueWidth = max(
            report.entries.map { displayValue($0).count }.max() ?? 0,
            "VALUE".count
        )
        var lines: [String] = []
        lines.append(
            headerRow(
            keyWidth: keyWidth,
            valueWidth: valueWidth
        )
            )
        lines.append(
            separatorRow(
            keyWidth: keyWidth,
            valueWidth: valueWidth
        )
            )
        for entry in report.entries {
            let key = entry.key.padding(
                toLength: keyWidth,
                withPad: " ",
                startingAt: 0
            )
            let value = displayValue(entry).padding(
                toLength: valueWidth,
                withPad: " ",
                startingAt: 0
            )
            lines.append("\(key)  \(value)  \(entry.source.rawValue)")
        }
        let notes = report.entries.compactMap { entry in
            entry.note.map { "note: \(entry.key) is unset: \($0)" }
        }
        if !notes.isEmpty {
            lines.append("")
            lines.append(contentsOf: notes)
        }
        if !report.warnings.isEmpty {
            lines.append("")
            for warning in report.warnings {
                lines.append("warning: \(warning)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func displayValue(_ entry: Entry) -> String {
        entry.source == .unset ? "-" : entry.value
    }

    private static func headerRow(keyWidth: Int, valueWidth: Int) -> String {
        let key = "KEY".padding(toLength: keyWidth, withPad: " ", startingAt: 0)
        let value = "VALUE".padding(toLength: valueWidth, withPad: " ", startingAt: 0)
        return "\(key)  \(value)  SOURCE"
    }

    private static func separatorRow(keyWidth: Int, valueWidth: Int) -> String {
        let key = String(repeating: "-", count: keyWidth)
        let value = String(repeating: "-", count: valueWidth)
        return "\(key)  \(value)  ------"
    }
}
