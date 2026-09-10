// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm pinch <f1x> <f1y> <f2x> <f2y> <tf1x> <tf1y> <tf2x> <tf2y>`.
struct PinchCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "pinch",
        abstract: "Two-finger interpolated path",
        usage: "deviceterm pinch <f1x> <f1y> <f2x> <f2y> "
            + "<tf1x> <tf1y> <tf2x> <tf2y> [--duration <ms>] [--pane <ref>]",
        discussion: HelpText.page(forTopic: "pinch") ?? ""
    )

    @Argument(help: "First finger start X, 0...1.")
    var fromF1X: Double

    @Argument(help: "First finger start Y, 0...1.")
    var fromF1Y: Double

    @Argument(help: "Second finger start X, 0...1.")
    var fromF2X: Double

    @Argument(help: "Second finger start Y, 0...1.")
    var fromF2Y: Double

    @Argument(help: "First finger end X, 0...1.")
    var toF1X: Double

    @Argument(help: "First finger end Y, 0...1.")
    var toF1Y: Double

    @Argument(help: "Second finger end X, 0...1.")
    var toF2X: Double

    @Argument(help: "Second finger end Y, 0...1.")
    var toF2Y: Double

    @Option(name: .long, help: "Gesture duration in milliseconds.")
    var duration: Int?

    @OptionGroup var paneOption: PaneOption
    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand {
        let coordinates = [
            fromF1X, fromF1Y, fromF2X, fromF2Y,
            toF1X, toF1Y, toF2X, toF2Y
        ]
        if let outside = CLICommands.firstCoordinateOutsideUnitRange(coordinates) {
            return .usage(message: CLICommands.coordinateRangeUsage(outside))
        }
        return .pinch(
            pane: paneOption.pane,
            fromF1X: fromF1X,
            fromF1Y: fromF1Y,
            fromF2X: fromF2X,
            fromF2Y: fromF2Y,
            toF1X: toF1X,
            toF1Y: toF1Y,
            toF2X: toF2X,
            toF2Y: toF2Y,
            durationMs: duration
            )
    }
}
