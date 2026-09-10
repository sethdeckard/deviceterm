// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm help [<topic>]`.
///
/// Declared so the parser tree includes the verb and the completion
/// scripts can read it; tests keep the hand-authored command list and
/// the static man page in step with the tree. It never parses:
/// `CLICommands.parse` intercepts a help trigger in the verb position,
/// because a bare `deviceterm help` prints the session's role above the
/// command list and the tree cannot produce that. `cliCommand` is the
/// answer for a bare invocation, so the verb still behaves if the
/// carve-out ever stops covering it.
struct HelpCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "help",
        abstract: "Print this list, or one command page in full",
        usage: "deviceterm help [<command>]",
        discussion: HelpText.page(forTopic: "help") ?? ""
    )

    @Argument(
        parsing: .remaining,
        help: "Command or concept to read.",
        completion: .list(Completions.helpTopics)
    )
    var topic: [String] = []

    var cliCommand: CLICommand {
        .help(topic: topic.isEmpty ? nil : topic.joined(separator: " "))
    }
}
