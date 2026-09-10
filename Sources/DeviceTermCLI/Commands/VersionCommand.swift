// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm version`.
struct VersionCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print deviceterm, daemon, wire, and macOS versions",
        discussion: HelpText.page(forTopic: "version") ?? ""
    )

    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand { .version }
}
