// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm tabs <list|current>`.
struct TabsCommand: CLICommandConvertible {
    struct List: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List every session you can see"
        )

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .tabsList }
    }

    struct Current: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "current",
            abstract: "Print your own session"
        )

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .tabsCurrent }
    }

    /// `usage` spells the sub-verbs rather than the generic
    /// `<subcommand>`, so a mistyped sub-verb is answered with the ones
    /// that exist instead of only the fact that this one does not.
    static let configuration = CommandConfiguration(
        commandName: "tabs",
        abstract: "List every session you can see, or print your own",
        usage: "deviceterm tabs <list|current>",
        discussion: HelpText.page(forTopic: "tabs") ?? "",
        subcommands: [List.self, Current.self]
    )

    /// Reached when no sub-verb was named.
    var cliCommand: CLICommand {
        .usage(message: "deviceterm: 'tabs' supports: list, current")
    }
}
