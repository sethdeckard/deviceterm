// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm with-pane <ref> <cmd> [args...]`.
///
/// Declared so the parser tree includes the verb and the completion
/// scripts can read it; tests keep the hand-authored command list and
/// the static man page in step with the tree. It never parses:
/// `CLICommands.parse` intercepts it, because everything after the ref
/// is the child's argv and has to reach the child byte for byte,
/// including tokens this parser would otherwise claim as its own.
struct WithPaneCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "with-pane",
        abstract: "Run a command with one pane pre-resolved",
        usage: "deviceterm with-pane <ref> <cmd> [args...]",
        discussion: HelpText.page(forTopic: "with-pane") ?? ""
    )

    var cliCommand: CLICommand {
        .usage(message: "usage: deviceterm with-pane <ref> <cmd> [args...]")
    }
}
