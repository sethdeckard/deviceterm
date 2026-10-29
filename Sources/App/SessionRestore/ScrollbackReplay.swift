// SPDX-License-Identifier: GPL-3.0-or-later

/// Turns saved scrollback into the output a restored terminal shows above its
/// first prompt.
///
/// Only shapes the text. Keeping it to display is libghostty's job: the
/// surface's `initial_output` preserves printable text, CR, LF, tab, and SGR,
/// discarding other controls and escape sequences, so nothing replayed can
/// make the terminal reply to the new shell or change its title or
/// clipboard.
enum ScrollbackReplay {
    /// The dim line shown below replayed scrollback, so it reads as history
    /// rather than as output from the new shell.
    static let marker = "\u{1B}[0;2m[restored scrollback]\u{1B}[0m"

    /// `saved` with rows ending in CRLF (capture ends them with LF), trailing
    /// blank rows dropped, styling reset, and `marker` on its own line; nil
    /// when nothing is left to show.
    static func output(from saved: String) -> String? {
        var rows = saved.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = rows.last, isBlank(last) {
            rows.removeLast()
        }
        guard !rows.isEmpty else { return nil }
        return rows.joined(separator: "\r\n") + "\u{1B}[0m\r\n" + marker + "\r\n"
    }

    /// Whether `row` shows nothing: only spaces, or SGR sequences and spaces.
    private static func isBlank(_ row: Substring) -> Bool {
        var inEscape = false
        for scalar in row.unicodeScalars {
            if inEscape {
                if scalar == "m" { inEscape = false }
                continue
            }
            switch scalar {
            case "\u{1B}":
                inEscape = true

            case " ", "\t", "\r":
                continue

            default:
                return false
            }
        }
        return true
    }
}
