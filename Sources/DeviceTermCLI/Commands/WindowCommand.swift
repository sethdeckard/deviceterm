// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm window <open|close|focus>`.
struct WindowCommand: CLICommandConvertible {
    struct Open: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "open",
            abstract: "Open a window"
        )

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .windowOpen }
    }

    struct Close: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "close",
            abstract: "Close a window",
            usage: "deviceterm window close [--window <ref>] [--mode <detach|shutdown>]"
        )

        @Option(
            name: .long,
            help: "Window to close.",
            completion: .custom { _, _, _ in RefCompletion.windows() }
        )
        var window: String?

        @Option(
            name: .long,
            help: "What to do with the devices: detach or shutdown.",
            completion: .list(Completions.closeModeValues)
        )
        var mode: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            .windowClose(
                window: CLICommands.parseWindowRef(window),
                mode: CLICommands.parseCloseMode(mode)
                )
        }
    }

    struct Focus: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "focus",
            abstract: "Bring a window to the front"
        )

        @Option(
            name: .long,
            help: "Window to focus.",
            completion: .custom { _, _, _ in RefCompletion.windows() }
        )
        var window: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .windowFocus(window: CLICommands.parseWindowRef(window)) }
    }

    static let subVerbList = "deviceterm: 'window' supports: open, close, focus"

    static let configuration = CommandConfiguration(
        commandName: "window",
        abstract: "Open, close, or focus a window",
        usage: "deviceterm window <open|close|focus>",
        discussion: HelpText.page(forTopic: "window") ?? "",
        subcommands: [Open.self, Close.self, Focus.self]
    )

    var cliCommand: CLICommand { .usage(message: Self.subVerbList) }
}
