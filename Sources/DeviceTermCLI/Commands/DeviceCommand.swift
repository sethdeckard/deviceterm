// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm device attach <ref>`.
///
/// The ref resolves against the `devices.list` roster at dispatch time
/// (sim UDID, physical deviceId, or device name); parsing only captures
/// it.
struct DeviceCommand: CLICommandConvertible {
    struct Attach: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "attach",
            abstract: "Attach a device to this tab as a pane",
            usage: "deviceterm device attach <ref>"
        )

        @Argument(help: "Sim UDID, device id, or device name.")
        var ref: String

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            guard !ref.isEmpty else {
                return .usage(message: Self.usageRefusal)
            }
            return .deviceAttach(ref: ref)
        }
    }

    static let subVerbList = "deviceterm: 'device' supports: attach"

    static let configuration = CommandConfiguration(
        commandName: "device",
        abstract: "Claim a sim or mirror a connected device into this tab",
        usage: "deviceterm device attach <ref>",
        discussion: HelpText.page(forTopic: "device") ?? "",
        subcommands: [Attach.self]
    )

    var cliCommand: CLICommand { .usage(message: Self.subVerbList) }
}
