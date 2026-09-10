// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm panes list`.
struct PanesCommand: CLICommandConvertible {
    struct List: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List the device panes in your tab"
        )

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .panesList }
    }

    static let configuration = CommandConfiguration(
        commandName: "panes",
        abstract: "List the device panes in your tab",
        usage: "deviceterm panes list",
        discussion: HelpText.page(forTopic: "panes") ?? "",
        subcommands: [List.self]
    )

    var cliCommand: CLICommand {
        .usage(message: "deviceterm: 'panes' supports: list")
    }
}
