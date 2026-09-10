// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm long-press <x> <y> [--duration <ms>]`.
struct LongPressCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "long-press",
        abstract: "Down at a point, hold, up at the same point",
        usage: "deviceterm long-press <x> <y> [--duration <ms>] [--pane <ref>]",
        discussion: HelpText.page(forTopic: "long-press") ?? ""
    )

    @Argument(help: "X in 0...1.")
    var x: Double

    @Argument(help: "Y in 0...1.")
    var y: Double

    @Option(name: .long, help: "Hold duration in milliseconds.")
    var duration: Int?

    @OptionGroup var paneOption: PaneOption
    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand {
        if let outside = CLICommands.firstCoordinateOutsideUnitRange([x, y]) {
            return .usage(message: CLICommands.coordinateRangeUsage(outside))
        }
        return .longPress(pane: paneOption.pane, x: x, y: y, durationMs: duration)
    }
}
