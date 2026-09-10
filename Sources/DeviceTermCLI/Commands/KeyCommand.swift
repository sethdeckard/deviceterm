// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm key <keyCode> <down|up>`.
///
/// The key code is read as a string so `parseKVKToken` can accept both
/// decimal and `0x`-prefixed hex. Apple's HIToolbox headers present the
/// `kVK_*` constants in hex, so a caller who looked one up should be
/// able to type what they read.
struct KeyCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Send a kVK virtual key code down or up",
        usage: "deviceterm key <keyCode> <down|up> [--pane <ref>]",
        discussion: HelpText.page(forTopic: "key") ?? ""
    )

    @Argument(help: "kVK code, decimal or 0x-prefixed hex.")
    var keyCode: String

    @Argument(help: "Direction: down or up.")
    var direction: String

    @OptionGroup var paneOption: PaneOption
    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand {
        guard let code = CLICommands.parseKVKToken(keyCode),
            direction == "down" || direction == "up" else {
            return .usage(
                message:
                "usage: deviceterm key <keyCode> <down|up> [--pane <ref>] "
                + "(decimal or 0x-prefixed hex)"
                )
        }
        return .key(pane: paneOption.pane, keyCode: code, down: direction == "down")
    }
}
