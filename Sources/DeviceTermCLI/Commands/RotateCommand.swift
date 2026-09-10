// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm rotate <orientation|direction>`.
///
/// A direction and an absolute orientation share one operand, so the
/// token is read as a string and matched whole. Matching on a prefix
/// would let an orientation spelling resolve to `left` or `right`.
struct RotateCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "rotate",
        abstract: "Set device orientation",
        usage: "deviceterm rotate <portrait|portrait-upside-down|landscape-left"
            + "|landscape-right|left|right> [--pane <ref>]",
        discussion: HelpText.page(forTopic: "rotate") ?? ""
    )

    @Argument(help: "Absolute orientation, or the direction to turn.")
    var target: String

    @OptionGroup var paneOption: PaneOption
    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand {
        guard let resolved = CLICommands.parseRotationTarget(target) else {
            return .usage(
                message:
                "usage: deviceterm rotate "
                + "<portrait|portrait-upside-down|landscape-left|landscape-right"
                + "|left|right> "
                + "[--pane <ref>]"
                )
        }
        return .rotate(pane: paneOption.pane, target: resolved)
    }
}
