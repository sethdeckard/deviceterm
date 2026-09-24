// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm fold <closed|book|open|0-180>`.
///
/// A posture name and an absolute angle share one operand, the way `rotate`
/// shares one between a direction and an orientation. The token is matched
/// whole and only then parsed as a number, so a name never resolves through
/// a numeric prefix.
struct FoldCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "fold",
        abstract: "Set the hinge angle of a foldable device",
        usage: "deviceterm fold <closed|book|open|0-180> [--pane <ref>]",
        discussion: HelpText.page(forTopic: "fold") ?? ""
    )

    @Argument(
        help: "A named posture, or the hinge angle in degrees.",
        completion: .list(Completions.foldValues)
    )
    var posture: String

    @OptionGroup var paneOption: PaneOption
    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand {
        guard let degrees = CLICommands.parseFoldPosture(posture) else {
            return .usage(
                message: "usage: deviceterm fold <closed|book|open|0-180> [--pane <ref>]"
            )
        }
        return .fold(pane: paneOption.pane, degrees: degrees)
    }
}
