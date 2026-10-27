// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm hardware-keyboard <on|off|status>`.
struct HardwareKeyboardCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "hardware-keyboard",
        abstract: "Turn the simulated hardware keyboard on or off",
        usage: "deviceterm hardware-keyboard <on|off|status> [--pane <ref>]",
        discussion: HelpText.page(forTopic: "hardware-keyboard") ?? ""
    )

    @Argument(
        help: "on, off, or status.",
        completion: .list(Completions.hardwareKeyboardValues)
    )
    var setting: String

    @OptionGroup var paneOption: PaneOption
    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand {
        switch setting {
        case "on":
            return .hardwareKeyboard(pane: paneOption.pane, enabled: true)

        case "off":
            return .hardwareKeyboard(pane: paneOption.pane, enabled: false)

        case "status":
            return .hardwareKeyboard(pane: paneOption.pane, enabled: nil)

        default:
            return .usage(message: "usage: deviceterm hardware-keyboard <on|off|status> [--pane <ref>]")
        }
    }
}
