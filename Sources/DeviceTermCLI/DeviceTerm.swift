// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// The `deviceterm` command tree.
///
/// `commandName` is set rather than derived because the executable
/// builds as `deviceterm-cli` and is symlinked into each session's
/// `bin/` as `deviceterm`. Every synthesized usage line and generated
/// help page reads this value, so a derived one would document a
/// command nobody types.
///
/// This is not the process entry point. `CLIMain` owns that, so a parse
/// failure lands on the CLI's own usage text and JSON failure envelope
/// instead of ArgumentParser exiting on its own.
struct DeviceTerm: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deviceterm",
        abstract: "Drive DeviceTerm tabs, panes, and the devices they show.",
        subcommands: [
            TextCommand.self,
            TabsCommand.self,
            PanesCommand.self,
            DevicesCommand.self,
            WindowsCommand.self,
            DoctorCommand.self,
            VersionCommand.self,
            DumpConfigCommand.self,
            EventsCommand.self,
            AgentsCommand.self
        ]
    )
}
