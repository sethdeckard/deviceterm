// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import Foundation

/// `deviceterm tab <open|close|rename|select|info|move|send-input|capture|set-protected>`.
struct TabCommand: CLICommandConvertible {
    struct Open: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "open",
            abstract: "Open a tab",
            usage: "deviceterm tab open [--window <ref>] [--cwd <path>] [--cmd '<cmd>']"
        )

        @Option(
            name: .long,
            help: "Window to open the tab in.",
            completion: .custom { _, _, _ in RefCompletion.windows() }
        )
        var window: String?

        @Option(name: .long, help: "Working directory for the tab's shell.")
        var cwd: String?

        @Option(name: .long, help: "Command to type after the login shell starts.")
        var cmd: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            .tabOpen(
                window: window.map(CLICommands.parseWindowRef),
                cwd: cwd,
                cmd: cmd
                )
        }
    }

    struct Close: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "close",
            abstract: "Close a tab",
            usage: "deviceterm tab close [--tab <ref>] [--mode <detach|shutdown>]"
        )

        @Option(
            name: .long,
            help: "Tab to close.",
            completion: .custom { _, _, _ in RefCompletion.tabs() }
        )
        var tab: String?

        @Option(
            name: .long,
            help: "What to do with the tab's device: detach or shutdown.",
            completion: .list(Completions.closeModeValues)
        )
        var mode: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            .tabClose(
                tab: CLICommands.parseTabRef(tab),
                mode: CLICommands.parseCloseMode(mode)
                )
        }
    }

    struct Rename: FreeTextCommand {
        static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: "Rename a tab, or clear its name",
            usage: "deviceterm tab rename [--tab <ref>] [<name>]"
        )

        @Option(
            name: .long,
            help: "Tab to rename.",
            completion: .custom { _, _, _ in RefCompletion.tabs() }
        )
        var tab: String?

        @OptionGroup var jsonFlag: JSONFlag

        @Argument(parsing: .remaining, help: "New name. Omit to clear it.")
        var words: [String] = []

        var cliCommand: CLICommand {
            let trimmed = words.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return .tabRename(
                tab: CLICommands.parseTabRef(tab),
                name: trimmed.isEmpty ? nil : trimmed
                )
        }
    }

    struct Select: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "select",
            abstract: "Bring a tab to the front"
        )

        @Option(
            name: .long,
            help: "Tab to select.",
            completion: .custom { _, _, _ in RefCompletion.tabs() }
        )
        var tab: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .tabSelect(tab: CLICommands.parseTabRef(tab)) }
    }

    struct Info: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Print one tab's identity and panes"
        )

        @Option(
            name: .long,
            help: "Tab to describe.",
            completion: .custom { _, _, _ in RefCompletion.tabs() }
        )
        var tab: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .tabInfo(tab: CLICommands.parseTabRef(tab)) }
    }

    struct Move: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "move",
            abstract: "Move a tab to an index or another window",
            usage: "deviceterm tab move [--tab <ref>] [--to <index>] [--to-window <ref>]"
        )

        @Option(
            name: .long,
            help: "Tab to move.",
            completion: .custom { _, _, _ in RefCompletion.tabs() }
        )
        var tab: String?

        @Option(name: .customLong("to"), help: "Destination index within the window.")
        var toIndex: Int?

        @Option(
            name: .customLong("to-window"),
            help: "Destination window.",
            completion: .custom { _, _, _ in RefCompletion.windows() }
        )
        var toWindow: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            let destination = toWindow.map(CLICommands.parseWindowRef)
            guard toIndex != nil || destination != nil else {
                return .usage(message: Self.usageRefusal)
            }
            return .tabMove(
                tab: CLICommands.parseTabRef(tab),
                toIndex: toIndex,
                toWindow: destination
                )
        }
    }

    struct SendInput: FreeTextCommand {
        static let configuration = CommandConfiguration(
            commandName: "send-input",
            abstract: "Type text into another tab's shell",
            usage: "deviceterm tab send-input [--tab <ref>] [--type-delay <ms>] <text>"
        )

        @Option(
            name: .long,
            help: "Tab to type into.",
            completion: .custom { _, _, _ in RefCompletion.tabs() }
        )
        var tab: String?

        @Option(name: .customLong("type-delay"), help: "Per-character delay in milliseconds.")
        var typeDelay: Int?

        @OptionGroup var jsonFlag: JSONFlag

        @Argument(parsing: .remaining, help: "Text to send. C-style escapes are decoded.")
        var words: [String] = []

        var cliCommand: CLICommand {
            let text = words.joined(separator: " ")
            guard !text.isEmpty else {
                return .usage(message: Self.usageRefusal)
            }
            if let typeDelay, typeDelay < 0 {
                return .usage(
                    message: "deviceterm: --type-delay expects a non-negative integer (milliseconds)"
                    )
            }
            return .tabSendInput(
                tab: CLICommands.parseTabRef(tab),
                text: CLICommands.decodeEscapes(text),
                typeDelay: typeDelay.map { min($0, CLICommands.maxTypeDelayMillis) }
                )
        }
    }

    struct Capture: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "capture",
            abstract: "Read another tab's visible terminal viewport",
            usage: "deviceterm tab capture [--tab <ref>]"
        )

        @Option(
            name: .long,
            help: "Tab to capture.",
            completion: .custom { _, _, _ in RefCompletion.tabs() }
        )
        var tab: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .tabCapture(tab: CLICommands.parseTabRef(tab)) }
    }

    struct SetProtected: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "set-protected",
            abstract: "Mark a tab protected, or clear the mark",
            usage: "deviceterm tab set-protected <true|false> [--tab <ref>]"
        )

        @Argument(help: "true or false.")
        var value: String

        @Option(
            name: .long,
            help: "Tab to mark.",
            completion: .custom { _, _, _ in RefCompletion.tabs() }
        )
        var tab: String?

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            let isProtected: Bool
            switch value.lowercased() {
            case "true", "yes", "on", "1":
                isProtected = true

            case "false", "no", "off", "0":
                isProtected = false

            default:
                return .usage(
                    message:
                    "deviceterm: 'tab set-protected' expects true or false; got '\(value)'"
                    )
            }
            return .tabSetProtected(tab: CLICommands.parseTabRef(tab), isProtected: isProtected)
        }
    }

    /// The sub-verbs, named in the refusal so a mistyped one is answered
    /// with the ones that exist.
    static let subVerbList = "deviceterm: 'tab' supports: open, close, rename, select, info, "
        + "move, send-input, capture, set-protected"

    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "Open, close, rename, move, or drive a tab",
        usage: "deviceterm tab <open|close|rename|select|info|move|send-input|capture"
            + "|set-protected>",
        discussion: HelpText.page(forTopic: "tab") ?? "",
        subcommands: [
            Open.self, Close.self, Rename.self, Select.self, Info.self,
            Move.self, SendInput.self, Capture.self, SetProtected.self
        ]
    )

    var cliCommand: CLICommand { .usage(message: Self.subVerbList) }
}
