// SPDX-License-Identifier: GPL-3.0-or-later

/// The `--json` toggle.
///
/// `--json` is a global presentation flag: it applies to every command
/// that emits human-readable output. The flag is detected separately
/// from `CLICommands.parse(_:)` so the per-command grammar stays
/// `--json`-unaware, since the splitter strips the token before dispatch so
/// commands like `tap 0.5 0.5 --json` still parse with the expected
/// positional arity.
///
/// Typed failures from JSON-capable commands emit a JSON error envelope
/// on stdout while preserving their human-readable stderr diagnostic.
/// AX commands always use JSON mode, including malformed invocations.
public enum OutputMode: String, Equatable, Sendable {
    /// Tab-separated receipt lines, list rows, etc: the default
    /// since shipping a CLI for terminals.
    case human
    /// Machine-parseable JSON object (or array, for list commands).
    /// Lists become arrays; receipts become objects with the same
    /// fields as the human form. AX commands already emit JSON; the
    /// flag is a no-op there.
    case json
}
