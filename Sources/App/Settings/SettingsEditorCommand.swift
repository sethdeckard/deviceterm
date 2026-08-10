// SPDX-License-Identifier: GPL-3.0-or-later
//
// SettingsEditorCommand: builds the argv tokens that get typed into a
// new tab's interactive login shell to open the deviceterm config in the
// user's editor.
//
// The editor token is left UNQUOTED so the tab's shell (which sources
// the user's `~/.zshrc`) expands `$VISUAL`/`$EDITOR` at type time. The
// GUI process's own environment usually has neither, so resolving in the
// shell is the only place they're reliably set. The path is single-
// quoted so a home directory containing spaces survives. `cmd` tokens
// are space-joined and typed as one line into the shell (see
// `TerminalCommand.loginShell(initialInput:)`).

import Foundation

enum SettingsEditorCommand {
    /// argv tokens for "open `path` in the user's editor", falling back
    /// `$VISUAL` → `$EDITOR` → `vi`. The fallback is resolved by the
    /// tab's shell, not here.
    static func tokens(forConfigPath path: String) -> [String] {
        ["${VISUAL:-${EDITOR:-vi}}", singleQuoted(path)]
    }

    /// POSIX single-quote a path: wrap in single quotes, rewriting any
    /// embedded single quote as the standard `'\''` escape.
    private static func singleQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
