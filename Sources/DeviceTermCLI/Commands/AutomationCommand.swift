// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import DaemonProtocol

/// Commands over the configured automation programs.
///
/// Both sub-verbs are deliberately argument-poor: neither takes a command,
/// a path, or a tab. The configuration file is the only place a program can
/// be named or its command given, and keeping that true is what stops this
/// surface from becoming a way to run arbitrary things in a granted tab.
struct AutomationCommand: CLICommandConvertible {
    struct Status: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show configured automation programs and their state"
        )

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .automationStatus }
    }

    struct Restart: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "restart",
            abstract: "Re-run configured automation programs"
        )

        @Option(name: .long, help: "Restart only this program. Default: all of them.")
        var name: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .automationRestart(name: name) }
    }

    static let subVerbList = "deviceterm: 'automation' supports: status, restart"

    static let configuration = CommandConfiguration(
        commandName: "automation",
        abstract: "Inspect and restart configured automation programs",
        usage: "deviceterm automation <status|restart>",
        discussion: HelpText.page(forTopic: "automation") ?? "",
        subcommands: [Status.self, Restart.self]
    )

    var cliCommand: CLICommand { .usage(message: Self.subVerbList) }
}
