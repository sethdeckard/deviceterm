// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation

/// `deviceterm pane <open|close|rename|info|move>`.
///
/// There is no `pane attach`: `deviceterm device attach <ref>` is the
/// one explicit-attach story.
struct PaneCommand: CLICommandConvertible {
    struct Open: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "open",
            abstract: "Open a terminal pane in a tab",
            usage: "deviceterm pane open --terminal [--tab <ref>] [--cwd <path>] [--cmd '<cmd>']"
        )

        @Flag(name: .long, help: "Open a terminal pane. Required.")
        var terminal = false

        @Option(name: .long, help: "Tab to open the pane in.")
        var tab: String?

        @Option(name: .long, help: "Working directory for the pane's shell.")
        var cwd: String?

        @Option(name: .long, help: "Command to type after the login shell starts.")
        var cmd: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            guard terminal else { return .usage(message: Self.usageRefusal) }
            return .paneOpenTerminal(
                tab: tab.map(CLICommands.parseTabRef),
                cwd: cwd,
                cmd: cmd
                )
        }
    }

    struct Close: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "close",
            abstract: "Close a pane",
            usage: "deviceterm pane close [--pane <ref>] [--mode <detach|shutdown>]"
        )

        @Option(name: .long, help: "Pane to close.")
        var pane: String?

        @Option(name: .long, help: "What to do with the device: detach or shutdown.")
        var mode: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            .paneClose(
                pane: CLICommands.parsePaneRef(pane),
                mode: CLICommands.parseCloseMode(mode)
                )
        }
    }

    struct Rename: FreeTextCommand {
        static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: "Pane rename (not implemented)",
            usage: "deviceterm pane rename [--pane <ref>] [<name>]"
        )

        @Option(name: .long, help: "Pane to rename.")
        var pane: String?

        @OptionGroup var jsonFlag: JSONFlag

        @Argument(parsing: .remaining, help: "New name. Omit to clear it.")
        var words: [String] = []

        var cliCommand: CLICommand {
            let trimmed = words.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return .paneRename(
                pane: CLICommands.parsePaneRef(pane),
                name: trimmed.isEmpty ? nil : trimmed
                )
        }
    }

    struct Info: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Print one pane's identity and device"
        )

        @Option(name: .long, help: "Pane to describe.")
        var pane: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .paneInfo(pane: CLICommands.parsePaneRef(pane)) }
    }

    struct Move: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "move",
            abstract: "Pane move (not implemented)",
            usage: "deviceterm pane move [--pane <ref>] --to-tab <ref>"
        )

        @Option(name: .long, help: "Pane to move.")
        var pane: String?

        @Option(name: .customLong("to-tab"), help: "Destination tab.")
        var toTab: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            guard let toTab, !toTab.isEmpty else {
                return .usage(message: Self.usageRefusal)
            }
            return .paneMove(
                pane: CLICommands.parsePaneRef(pane),
                toTab: CLICommands.parseTabRef(toTab)
                )
        }
    }

    static let subVerbList = "deviceterm: 'pane' supports: open, close, rename, info, move"

    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "Open, close, or inspect a pane",
        usage: "deviceterm pane <open|close|rename|info|move>",
        discussion: HelpText.page(forTopic: "pane") ?? "",
        subcommands: [Open.self, Close.self, Rename.self, Info.self, Move.self]
    )

    var cliCommand: CLICommand { .usage(message: Self.subVerbList) }
}
