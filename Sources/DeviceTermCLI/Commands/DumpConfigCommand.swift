// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm dump-config`.
struct DumpConfigCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "dump-config",
        abstract: "Print every config key with its value and source",
        discussion: HelpText.page(forTopic: "dump-config") ?? ""
    )

    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand { .dumpConfig }
}
