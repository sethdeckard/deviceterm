// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser

/// `deviceterm completions install <zsh|bash|fish>`.
struct CompletionsCommand: CLICommandConvertible {
    struct Install: CLICommandConvertible {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Write the completion script for a shell",
            usage: "deviceterm completions install <zsh|bash|fish>"
        )

        @Argument(
            help: "Shell to install for: zsh, bash, or fish.",
            completion: .list(Completions.Shell.allCases.map(\.rawValue))
        )
        var shell: String

        @OptionGroup var jsonFlag: JSONFlag

        var cliCommand: CLICommand {
            guard let resolved = Completions.Shell(rawValue: shell) else {
                return .usage(message: Self.usageRefusal)
            }
            return .completionsInstall(shell: resolved)
        }
    }

    static let usageLine = "deviceterm completions install <zsh|bash|fish>"

    static let configuration = CommandConfiguration(
        commandName: "completions",
        abstract: "Install the zsh, bash, or fish completion script",
        usage: usageLine,
        discussion: HelpText.page(forTopic: "completions") ?? "",
        subcommands: [Install.self]
    )

    var cliCommand: CLICommand { .usage(message: Self.usageRefusal) }
}
