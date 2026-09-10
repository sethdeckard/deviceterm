// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm devices list`.
struct DevicesCommand: CLICommandConvertible {
    struct List: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "The live roster of owned booted sims and connected devices"
        )

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .devicesList }
    }

    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "The live roster of owned booted sims and connected devices",
        usage: "deviceterm devices list",
        discussion: HelpText.page(forTopic: "devices") ?? "",
        subcommands: [List.self]
    )

    var cliCommand: CLICommand {
        .usage(message: "deviceterm: 'devices' supports: list")
    }
}
