// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import DaemonProtocol

/// Commands over DeviceTerm windows.
struct WindowCommand: CLICommandConvertible {
    struct List: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List windows"
        )

        @Flag(name: .long, help: "List every caller-visible window.")
        var all = false

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .windowList(all: all) }
    }

    struct Show: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show one window and its tabs"
        )

        @Argument(help: "Window reference. Defaults to current.")
        var window: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .windowShow(window: window) }
    }

    struct Open: CLICommandConvertible {
        static let configuration = CommandConfiguration(commandName: "open", abstract: "Open a window")

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .windowOpen }
    }

    struct Focus: CLICommandConvertible {
        static let configuration = CommandConfiguration(commandName: "focus", abstract: "Focus a window")

        @Argument(help: "Window reference. Defaults to current.")
        var window: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .windowFocus(window: window) }
    }

    struct Close: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "close",
            abstract: "Close a window",
            usage: "deviceterm window close [<window>] [--mode <detach|shutdown>]"
        )

        @Argument(help: "Window reference. Defaults to current.")
        var window: String?

        @Option(name: .long, help: "Simulator disposition: detach or shutdown.")
        var mode: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            guard let parsed = WorkspaceCloseMode(rawValue: mode ?? WorkspaceCloseMode.detach.rawValue) else {
                return .usage(message: "deviceterm: --mode expects detach or shutdown")
            }
            return .windowClose(window: window, mode: parsed)
        }
    }

    static let subVerbList = "deviceterm: 'window' supports: list, show, open, focus, close"

    static let configuration = CommandConfiguration(
        commandName: "window",
        abstract: "List, inspect, or change windows",
        usage: "deviceterm window <list|show|open|focus|close>",
        discussion: HelpText.page(forTopic: "window") ?? "",
        subcommands: [List.self, Show.self, Open.self, Focus.self, Close.self]
    )

    var cliCommand: CLICommand { .usage(message: Self.subVerbList) }
}
