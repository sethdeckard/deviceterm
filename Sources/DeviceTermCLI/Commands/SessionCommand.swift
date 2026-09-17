// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import DaemonProtocol

/// Commands over the calling session.
struct SessionCommand: CLICommandConvertible {
    struct Show: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show this session's identity and authority"
        )

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .sessionShow }
    }

    static let subVerbList = "deviceterm: 'session' supports: show"

    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Inspect the calling session",
        usage: "deviceterm session <show>",
        discussion: HelpText.page(forTopic: "session") ?? "",
        subcommands: [Show.self]
    )

    var cliCommand: CLICommand { .usage(message: Self.subVerbList) }
}
