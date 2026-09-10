// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm agents`.
struct AgentsCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "agents",
        abstract: "Workflow recipes and triage for agents",
        discussion: HelpText.page(forTopic: "agents") ?? ""
    )

    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand { .agents }
}
