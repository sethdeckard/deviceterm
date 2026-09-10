// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm app-switcher [--pane <ref>]`.
struct AppSwitcherCommand: CLICommandConvertible {
    static let configuration = CommandConfiguration(
        commandName: "app-switcher",
        abstract: "Open the iOS App Switcher",
        usage: "deviceterm app-switcher [--pane <ref>]",
        discussion: HelpText.page(forTopic: "app-switcher") ?? ""
    )

    @OptionGroup var paneOption: PaneOption
    @OptionGroup var jsonFlag: JSONFlag

    var cliCommand: CLICommand { .appSwitcher(pane: paneOption.pane) }
}
