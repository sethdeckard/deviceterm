// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm doctor`.
struct DoctorCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check env, daemon, and session health",
        discussion: HelpText.page(forTopic: "doctor") ?? ""
    )

    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand { .doctor }
}
