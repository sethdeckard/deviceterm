// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm swipe <fromX> <fromY> <toX> <toY>`.
struct SwipeCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "Interpolated drag between two points",
        usage: "deviceterm swipe <fromX> <fromY> <toX> <toY> "
            + "[--duration <ms>] [--hold <ms>] [--pane <ref>]",
        discussion: HelpText.page(forTopic: "swipe") ?? ""
    )

    @Argument(help: "Start X, 0...1.")
    var fromX: Double

    @Argument(help: "Start Y, 0...1.")
    var fromY: Double

    @Argument(help: "End X, 0...1.")
    var toX: Double

    @Argument(help: "End Y, 0...1.")
    var toY: Double

    @Option(name: .long, help: "Gesture duration in milliseconds.")
    var duration: Int?

    @Option(name: .long, help: "Dwell at the end point in milliseconds.")
    var hold: Int?

    @OptionGroup var paneOption: PaneOption
    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand {
        let coordinates = [fromX, fromY, toX, toY]
        if let outside = CLICommands.firstCoordinateOutsideUnitRange(coordinates) {
            return .usage(message: CLICommands.coordinateRangeUsage(outside))
        }
        return .swipe(
            pane: paneOption.pane,
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            durationMs: duration,
            holdMs: hold
            )
    }
}
