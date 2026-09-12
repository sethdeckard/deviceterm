// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import DaemonProtocol
import Foundation

/// Commands over tab workspaces.
struct TabCommand: CLICommandConvertible {
    struct List: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List tab workspaces"
        )

        @Option(name: .long, help: "Window whose tabs to list.")
        var window: String?

        @Flag(name: .long, help: "List tabs in every visible window.")
        var all = false

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            guard !(all && window != nil) else {
                return .usage(message: "deviceterm: tab list accepts --window or --all, not both")
            }
            return .tabList(window: window, all: all)
        }
    }

    struct Show: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show one tab and its pane layout"
        )

        @Argument(help: "Tab reference. Defaults to current.")
        var tab: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .tabShow(tab: tab) }
    }

    struct Open: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "open",
            abstract: "Open a tab",
            usage: "deviceterm tab open [--window <ref>] [--cwd <path>] [--command '<cmd>']"
        )

        @Option(name: .long, help: "Window to open the tab in.")
        var window: String?

        @Option(name: .long, help: "Working directory for the tab's shell.")
        var cwd: String?

        @Option(name: .long, help: "Command to type after the login shell starts.")
        var command: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            .tabOpen(window: window, cwd: cwd, command: command)
        }
    }

    struct Close: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "close",
            abstract: "Close a tab",
            usage: "deviceterm tab close [<tab>] [--mode <detach|shutdown>]"
        )

        @Argument(help: "Tab reference. Defaults to current.")
        var tab: String?

        @Option(name: .long, help: "Simulator disposition: detach or shutdown.")
        var mode: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            guard let parsed = WorkspaceCloseMode(rawValue: mode ?? WorkspaceCloseMode.detach.rawValue) else {
                return .usage(message: "deviceterm: --mode expects detach or shutdown")
            }
            return .tabClose(tab: tab, mode: parsed)
        }
    }

    struct Rename: FreeTextCommand {
        static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: "Assign or clear a tab name",
            usage: "deviceterm tab rename [<tab>] <name>",
            discussion: """
            Names occupy one positional argument. Quote a name containing spaces.
            A word beginning with - is read as a flag. Put -- before the name to use it literally.
            """
        )

        @OptionGroup var jsonFlag: JSONFlag

        @Argument(help: "Name for the current tab, or a tab reference when <name> follows.")
        var targetOrName: String?

        @Argument(help: "Name for an explicitly referenced tab.")
        var explicitName: String?

        var cliCommand: CLICommand {
            guard let targetOrName else { return .usage(message: Self.usageRefusal) }
            let tab = explicitName == nil ? nil : targetOrName
            let name = (explicitName ?? targetOrName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .tabRename(tab: tab, name: name.isEmpty ? nil : name)
        }
    }

    struct Focus: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "focus",
            abstract: "Select a tab in its window"
        )

        @Argument(help: "Tab reference. Defaults to current.")
        var tab: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .tabFocus(tab: tab) }
    }

    struct Move: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "move",
            abstract: "Move a tab to a window",
            usage: "deviceterm tab move [<tab>] --window <window> [--index <n>]"
        )

        @Argument(help: "Tab reference. Defaults to current.")
        var tab: String?

        @Option(name: .long, help: "Destination window.")
        var window: String?

        @Option(name: .long, help: "Zero-based destination index. Omit to append.")
        var index: Int?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            guard let window, !window.isEmpty else {
                return .usage(message: Self.usageRefusal)
            }
            guard index.map({ $0 >= 0 }) ?? true else {
                return .usage(message: "deviceterm: --index expects a non-negative integer")
            }
            return .tabMove(tab: tab, window: window, index: index)
        }
    }

    struct Protect: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "protect",
            abstract: "Hide a tab from other sessions"
        )

        @Argument(help: "Tab reference. Defaults to current.")
        var tab: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .tabProtect(tab: tab) }
    }

    struct Unprotect: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "unprotect",
            abstract: "Make a tab visible to other sessions"
        )

        @Argument(help: "Tab reference. Defaults to current.")
        var tab: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .tabUnprotect(tab: tab) }
    }

    static let subVerbList = "deviceterm: 'tab' supports: list, show, open, close, rename, focus, "
        + "move, protect, unprotect"

    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "List, inspect, or change tab workspaces",
        usage: "deviceterm tab <list|show|open|close|rename|focus|move|protect|unprotect>",
        discussion: HelpText.page(forTopic: "tab") ?? "",
        subcommands: [
            List.self,
            Show.self,
            Open.self,
            Close.self,
            Rename.self,
            Focus.self,
            Move.self,
            Protect.self,
            Unprotect.self
        ]
    )

    var cliCommand: CLICommand { .usage(message: Self.subVerbList) }
}
