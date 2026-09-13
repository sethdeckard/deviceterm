// SPDX-License-Identifier: GPL-3.0-or-later

/// How a terminal capture renders the cells it reads.
///
/// `ansi` is not `plain` with escape sequences interleaved. Two
/// differences survive stripping them. A trailing cell holding a
/// background but no character is captured as a space, which `plain`
/// drops; interior ones become spaces in both, because a later
/// character on the row flushes them. And the engine separates styled
/// rows with CRLF, which the capture normalizes back to `\n` so both
/// formats agree on row boundaries.
///
/// The two match after stripping escape sequences and trimming trailing
/// whitespace on each row. Row counts always match, because the engine
/// decides row blankness from characters alone and ignores styling.
public enum TerminalTextFormat: Sendable, Equatable {
    /// Rendered characters only, no styling.
    case plain

    /// Characters plus SGR color and style sequences. Palette colors stay
    /// as palette indexes so the consumer applies its own theme; direct
    /// RGB passes through unchanged.
    case ansi
}
