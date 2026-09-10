// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm events`.
///
/// Output is always JSON, so the declared `--json` is accepted and
/// ignored here exactly as it is everywhere else.
struct EventsCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Stream pane and device events as JSON lines",
        discussion: HelpText.page(forTopic: "events") ?? ""
    )

    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand { .events }
}
