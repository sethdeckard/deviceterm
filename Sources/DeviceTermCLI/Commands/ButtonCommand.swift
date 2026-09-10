// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import DaemonProtocol

/// `deviceterm button <home|lock|side|apple-pay|siri|digital-crown>`.
///
/// The name is read as a string and normalized through `parseEnumArg`,
/// which accepts the hyphenated and camel-cased spellings alike, so a
/// caller who copied `digitalCrown` out of a JSON receipt is understood.
struct ButtonCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "button",
        abstract: "Press a hardware button",
        usage: "deviceterm button <home|lock|side|apple-pay|siri|digital-crown> [--pane <ref>]",
        discussion: HelpText.page(forTopic: "button") ?? ""
    )

    @Argument(help: "Button name.", completion: .list(Completions.buttonValues))
    var name: String

    @OptionGroup var paneOption: PaneOption
    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand {
        guard let button = CLICommands.parseEnumArg(name, as: HardwareButton.self) else {
            return .usage(
                message:
                "usage: deviceterm button "
                + "<home|lock|side|apple-pay|siri|digital-crown> [--pane <ref>]"
                )
        }
        return .button(pane: paneOption.pane, button: button)
    }
}
