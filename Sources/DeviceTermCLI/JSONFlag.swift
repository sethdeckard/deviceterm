// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// The `--json` switch, declared on every leaf.
///
/// Its parsed value is deliberately never read. Output mode is settled
/// before parsing by `CLICommands.outputMode(for:)`, which encodes rules
/// this declaration cannot express: the flag counts anywhere ahead of a
/// bare `--`, stays literal after one, belongs to the child rather than
/// to deviceterm once `with-pane` has claimed the tail, and has to be
/// known even when parsing goes on to fail, so a malformed invocation
/// can still answer in JSON. The declaration earns its place by putting
/// the flag in the generated usage and help pages.
struct JSONFlag: ParsableArguments {
    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false
}
