// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm windows list [--all]`.
struct WindowsCommand: CLICommandConvertible {
    struct List: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List the windows you can see"
        )

        @Flag(name: .long, help: "Include windows this session does not own.")
        var all = false

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .windowsList(all: all) }
    }

    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List the windows you can see",
        usage: "deviceterm windows list",
        discussion: HelpText.page(forTopic: "windows") ?? "",
        subcommands: [List.self]
    )

    var cliCommand: CLICommand {
        .usage(message: "deviceterm: 'windows' supports: list")
    }
}
