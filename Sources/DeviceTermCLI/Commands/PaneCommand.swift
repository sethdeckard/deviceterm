// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import DaemonProtocol
import Foundation

/// Commands over terminal, Simulator, and physical-device panes.
struct PaneCommand: CLICommandConvertible {
    struct List: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List every pane in layout order"
        )

        @Option(name: .long, help: "Tab whose panes to list.")
        var tab: String?

        @Flag(name: .long, help: "List panes in every visible tab.")
        var all = false

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            guard !(all && tab != nil) else {
                return .usage(message: "deviceterm: pane list accepts --tab or --all, not both")
            }
            return .paneList(tab: tab, all: all)
        }
    }

    struct Show: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show one pane"
        )

        @Argument(help: "Pane reference. Defaults to current.")
        var pane: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .paneShow(pane: pane) }
    }

    struct Split: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "split",
            abstract: "Create a terminal pane beside an anchor",
            usage: "deviceterm pane split [<pane>] --direction <left|right|up|down>"
        )

        @Argument(help: "Anchor pane. Defaults to current.")
        var pane: String?

        @Option(name: .long, help: "Placement relative to the anchor.")
        var direction: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            guard let direction, let parsed = WorkspaceSplitDirection(rawValue: direction) else {
                return .usage(message: "deviceterm: --direction expects left, right, up, or down")
            }
            return .paneSplit(pane: pane, direction: parsed)
        }
    }

    struct Focus: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "focus",
            abstract: "Give a pane keyboard focus"
        )

        @Argument(help: "Pane reference. Defaults to current.")
        var pane: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .paneFocus(pane: pane) }
    }

    struct Close: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "close",
            abstract: "Close a pane",
            usage: "deviceterm pane close [<pane>] [--mode <detach|shutdown>]"
        )

        @Argument(help: "Pane reference. Defaults to current.")
        var pane: String?

        @Option(name: .long, help: "Simulator disposition: detach or shutdown.")
        var mode: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            let parsed = mode.flatMap(WorkspaceCloseMode.init(rawValue:))
            guard mode == nil || parsed != nil else {
                return .usage(message: "deviceterm: --mode expects detach or shutdown")
            }
            return .paneClose(pane: pane, mode: parsed)
        }
    }

    struct Rename: FreeTextCommand {
        static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: "Assign or clear a pane name",
            usage: "deviceterm pane rename [<pane>] <name>",
            discussion: """
            Names occupy one positional argument. Quote a name containing spaces.
            A word beginning with - is read as a flag. Put -- before the name to use it literally.
            """
        )

        @OptionGroup var jsonFlag: JSONFlag

        @Argument(help: "Name for the current pane, or a pane reference when <name> follows.")
        var targetOrName: String?

        @Argument(help: "Name for an explicitly referenced pane.")
        var explicitName: String?

        var cliCommand: CLICommand {
            guard let targetOrName else { return .usage(message: Self.usageRefusal) }
            let pane = explicitName == nil ? nil : targetOrName
            let name = (explicitName ?? targetOrName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .paneRename(pane: pane, name: name.isEmpty ? nil : name)
        }
    }

    struct SendInput: FreeTextCommand {
        static let configuration = CommandConfiguration(
            commandName: "send-input",
            abstract: "Type text into a terminal pane",
            usage: "deviceterm pane send-input <pane> [--type-delay <ms>] <text>"
        )

        @Argument(help: "Terminal pane reference.")
        var pane: String

        @Option(name: .customLong("type-delay"), help: "Per-character delay in milliseconds.")
        var typeDelay: Int?

        @OptionGroup var jsonFlag: JSONFlag

        @Argument(
            parsing: .remaining,
            help: """
            Text to send. C-style escapes are decoded.
            Put -- before dashed text. A word beginning with - is read as a flag.
            """
        )
        var words: [String] = []

        var cliCommand: CLICommand {
            let text = words.joined(separator: " ")
            guard !text.isEmpty else { return .usage(message: Self.usageRefusal) }
            guard typeDelay.map({ $0 >= 0 }) ?? true else {
                return .usage(message: "deviceterm: --type-delay expects a non-negative integer")
            }
            return .paneSendInput(
                pane: pane,
                text: CLICommands.decodeEscapes(text),
                typeDelay: typeDelay.map { min($0, CLICommands.maxTypeDelayMillis) }
            )
        }
    }

    struct CaptureText: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "capture-text",
            abstract: "Capture a terminal pane's visible text",
            usage: "deviceterm pane capture-text <pane> [--ansi] [--json]"
        )

        @Argument(help: "Terminal pane reference.")
        var pane: String

        @Flag(
            name: .customLong("ansi"),
            help: "Keep SGR color and style escape sequences in the text."
        )
        var ansi = false

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .paneCaptureText(pane: pane, ansi: ansi) }
    }

    static let subVerbList = "deviceterm: 'pane' supports: list, show, split, focus, close, rename, "
        + "send-input, capture-text"

    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "List, inspect, split, or drive panes",
        usage: "deviceterm pane <list|show|split|focus|close|rename|send-input|capture-text>",
        discussion: HelpText.page(forTopic: "pane") ?? "",
        subcommands: [
            List.self,
            Show.self,
            Split.self,
            Focus.self,
            Close.self,
            Rename.self,
            SendInput.self,
            CaptureText.self
        ]
    )

    var cliCommand: CLICommand { .usage(message: Self.subVerbList) }
}
