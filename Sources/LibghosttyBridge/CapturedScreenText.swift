// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Post-processing shared by every screen capture, whatever its format.
enum CapturedScreenText {
    /// Rewrite CRLF row separators as `\n`.
    ///
    /// The engine's styled formatter ends each row with CRLF so the output
    /// replays correctly when written straight back to a terminal, while
    /// the plain formatter uses `\n`. Callers compare the two and join
    /// rows themselves, so the capture settles on `\n` for both rather
    /// than making every consumer handle the difference.
    ///
    /// A lone CR is left alone: it is content the terminal emitted, not a
    /// row separator.
    static func normalizingRowSeparators(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }
}
