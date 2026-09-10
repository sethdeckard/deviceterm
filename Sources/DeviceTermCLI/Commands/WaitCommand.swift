// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import DaemonProtocol

/// `deviceterm wait <pane|ax|orientation|surface> ...`.
struct WaitCommand: CLICommandConvertible {
    struct Pane: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "pane",
            abstract: "Block until the pane reaches a lifecycle state",
            usage: "deviceterm wait pane <booting|rendering|shutdown|failed> "
                + "[--pane <ref>] [--timeout <ms>]"
        )

        @Argument(
            help: "Lifecycle state to wait for.",
            completion: .list(Completions.waitPaneValues)
        )
        var state: String?

        @OptionGroup var options: WaitOptions

        var cliCommand: CLICommand {
            // `wait pane --state rendering` is the natural mis-spelling
            // once `--state` exists, and the generic usage explains it
            // badly.
            guard let state else {
                // Only a `--state` naming a lifecycle earns the targeted
                // message. A genuine typo has no business being told
                // about `wait pane`, so it keeps the generic usage.
                guard options.state.map({ PaneLifecycle(rawValue: $0) != nil }) == true else {
                    return .usage(message: WaitCommand.genericUsage)
                }
                return .usage(
                    message: "usage: deviceterm wait pane "
                        + "<booting|rendering|shutdown|failed> [--timeout <ms>]"
                    )
            }
            guard let lifecycle = PaneLifecycle(rawValue: state) else {
                return .usage(message: Self.usageRefusal)
            }
            if let refusal = options.foreignFlagRefusal(subVerb: "pane") { return refusal }
            if let refusal = options.timeoutRefusal { return refusal }
            return .waitPane(
                pane: options.paneOption.pane,
                state: lifecycle,
                timeoutMs: options.deadlineMillis
                )
        }
    }

    struct Orientation: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "orientation",
            abstract: "Block until the device reports an orientation",
            usage: "deviceterm wait orientation <orientation> [--pane <ref>] [--timeout <ms>]"
        )

        @Argument(
            help: "Orientation to wait for.",
            completion: .list(Completions.waitOrientationValues)
        )
        var orientation: String

        @OptionGroup var options: WaitOptions

        var cliCommand: CLICommand {
            guard let target = CLICommands.parseEnumArg(
                orientation,
                as: DaemonProtocol.Orientation.self
            ) else {
                return .usage(message: Self.usageRefusal)
            }
            if let refusal = options.foreignFlagRefusal(subVerb: "orientation") { return refusal }
            if let refusal = options.timeoutRefusal { return refusal }
            return .waitOrientation(
                pane: options.paneOption.pane,
                orientation: target,
                timeoutMs: options.deadlineMillis
                )
        }
    }

    struct Surface: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "surface",
            abstract: "Block until the pane's rendering settles",
            usage: "deviceterm wait surface quiescent "
                + "[--settle <ms>] [--pane <ref>] [--timeout <ms>]"
        )

        @Argument(
            help: "The only mode: quiescent.",
            completion: .list(Completions.surfaceConditionValues)
        )
        var mode: String?

        @OptionGroup var options: WaitOptions

        var cliCommand: CLICommand {
            guard mode == "quiescent" else {
                return .usage(message: Self.usageRefusal)
            }
            if let refusal = options.foreignFlagRefusal(subVerb: "surface") { return refusal }
            // Zero is a legitimate ask: one unchanged observation rather
            // than a window of stillness. Negative is not.
            let settle = options.settle ?? CLICommands.defaultSettleMillis
            guard settle >= 0 else {
                return .usage(message: "deviceterm: --settle cannot be negative")
            }
            if let refusal = options.timeoutRefusal { return refusal }
            return .waitSurfaceQuiescent(
                pane: options.paneOption.pane,
                settleMs: settle,
                timeoutMs: options.deadlineMillis
                )
        }
    }

    struct Accessibility: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "ax",
            abstract: "Block until an accessibility selector resolves"
        )

        @OptionGroup var options: WaitOptions

        var cliCommand: CLICommand {
            if let refusal = options.foreignFlagRefusal(subVerb: "ax") { return refusal }
            let query: CLICommand.WaitAXQuery
            switch options.selector.resolve(verb: "wait ax") {
            case let .usage(message):
                return .usage(message: message)

            case let .query(parsed):
                query = parsed
            }
            let printMode: CLICommand.WaitAXPrint?
            if let raw = options.print {
                guard let mode = CLICommand.WaitAXPrint(rawValue: raw) else {
                    return .usage(message: "deviceterm: --print must be center")
                }
                printMode = mode
            } else {
                printMode = nil
            }
            guard let state = CLICommand.WaitAXState(rawValue: options.state ?? "present") else {
                return .usage(message: "deviceterm: --state must be present or absent")
            }
            // Nothing to print once the element is gone, and refusing is
            // clearer than succeeding with empty stdout, which is what a
            // refusal looks like.
            if state == .absent, printMode != nil {
                return .usage(
                    message: "deviceterm: --print cannot be combined with --state absent"
                )
            }
            if let refusal = options.timeoutRefusal { return refusal }
            return .waitAX(
                pane: options.paneOption.pane,
                query: query,
                timeoutMs: options.deadlineMillis,
                printMode: printMode,
                state: state
                )
        }
    }

    /// The whole-verb usage, which a sub-verb falls back to when the
    /// mistake says nothing about which wait was meant.
    static let genericUsage = "usage: deviceterm wait "
        + "<pane|ax|orientation|surface> ... [--timeout <ms>]"

    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Block until an observable device condition holds",
        usage: "deviceterm wait <pane|ax|orientation|surface> ... [--timeout <ms>]",
        discussion: HelpText.page(forTopic: "wait") ?? "",
        subcommands: [Pane.self, Accessibility.self, Orientation.self, Surface.self]
    )

    var cliCommand: CLICommand { .usage(message: Self.genericUsage) }
}
