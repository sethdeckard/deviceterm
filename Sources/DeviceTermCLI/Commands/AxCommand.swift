// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm ax <tree|point|sweep>`.
///
/// The family answers in JSON with no flag, which `outputMode(for:)`
/// decides before parsing.
struct AxCommand: CLICommandConvertible {
    struct Tree: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "tree",
            abstract: "Dump the pane's accessibility tree"
        )

        @OptionGroup var paneOption: PaneOption
        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand { .axTree(pane: paneOption.pane) }
    }

    struct Point: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "point",
            abstract: "Describe the element at a coordinate"
        )

        @Argument(help: "X in 0...1.")
        var x: Double

        @Argument(help: "Y in 0...1.")
        var y: Double

        @OptionGroup var paneOption: PaneOption
        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            if let outside = CLICommands.firstCoordinateOutsideUnitRange([x, y]) {
                return .usage(message: CLICommands.coordinateRangeUsage(outside))
            }
            return .axPoint(pane: paneOption.pane, x: x, y: y)
        }
    }

    struct Sweep: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "sweep",
            abstract: "Probe the pane on a grid and report what answers"
        )

        @Option(name: .long, help: "Grid spacing, 0...1.")
        var step: Double?

        @Option(name: .long, help: "Sweep budget in milliseconds.")
        var budget: Int?

        @OptionGroup var paneOption: PaneOption
        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            .axSweep(pane: paneOption.pane, step: step, budgetMs: budget)
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "ax",
        abstract: "Dump the accessibility tree, one point, or a grid sweep",
        usage: "deviceterm ax tree | ax point <x> <y> "
            + "| ax sweep [--step <0..1>] [--budget <ms>] [--pane <ref>]",
        discussion: HelpText.page(forTopic: "ax") ?? "",
        subcommands: [Tree.self, Point.self, Sweep.self]
    )

    var cliCommand: CLICommand {
        .usage(
            message:
            "usage: deviceterm ax tree | ax point <x> <y> "
            + "| ax sweep [--step <0..1>] [--budget <ms>] [--pane <ref>]"
            )
    }
}
