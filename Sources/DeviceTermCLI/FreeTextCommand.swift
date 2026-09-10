// SPDX-License-Identifier: GPL-3.0-or-later

/// A command whose payload is arbitrary text rather than a fixed set of
/// operands.
///
/// These are the commands where a word beginning with `-` is ambiguous:
/// the parser reads it as a flag, and the caller meant to send it. They
/// are marked so a refusal can name the `--` terminator that resolves
/// it, which is the difference between a dead end and a fix.
protocol FreeTextCommand: CLICommandConvertible {}
