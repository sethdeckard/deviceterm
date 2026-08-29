// SPDX-License-Identifier: GPL-3.0-or-later

@testable import DeviceTermCLI
import Foundation
import Testing

// `deviceterm completions install <shell>` parser + the pure
// `Completions` emitters and path resolver. main.swift handles the
// disk write; these tests pin the script invariants and the install-
// path conventions so a release can't ship completion scripts that
// silently drop a verb or land in a directory that isn't on the
// shell's autoload path.

// MARK: - Parser

@Test
func parseCompletionsInstallZsh() {
    #expect(
        CLICommands.parse(["deviceterm", "completions", "install", "zsh"])
        == .completionsInstall(shell: .zsh)
        )
}

@Test
func parseCompletionsInstallBash() {
    #expect(
        CLICommands.parse(["deviceterm", "completions", "install", "bash"])
        == .completionsInstall(shell: .bash)
        )
}

@Test
func parseCompletionsInstallFish() {
    #expect(
        CLICommands.parse(["deviceterm", "completions", "install", "fish"])
        == .completionsInstall(shell: .fish)
        )
}

@Test
func parseCompletionsInstallRespectsJSONStrip() {
    // Global --json strip applies; the parser still resolves the
    // verb. main.swift dispatches the install (which doesn't honor
    // --json, since it's a documentation surface, like --help / agents).
    #expect(
        CLICommands.parse(
        ["deviceterm", "--json", "completions", "install", "zsh"]
    )
        == .completionsInstall(shell: .zsh)
        )
}

@Test
func parseCompletionsInstallRejectsUnknownShell() {
    let result = CLICommands.parse(
        ["deviceterm", "completions", "install", "tcsh"]
    )
    if case let .usage(message) = result {
        #expect(message?.contains("zsh|bash|fish") ?? false)
    } else {
        Issue.record("expected usage, got \(result)")
    }
}

@Test
func parseCompletionsWithoutSubVerbIsUsage() {
    let result = CLICommands.parse(["deviceterm", "completions"])
    if case let .usage(message) = result {
        #expect(message?.contains("install") ?? false)
    } else {
        Issue.record("expected usage, got \(result)")
    }
}

@Test
func parseCompletionsInstallWithoutShellIsUsage() {
    let result = CLICommands.parse(["deviceterm", "completions", "install"])
    if case let .usage(message) = result {
        #expect(message?.contains("zsh|bash|fish") ?? false)
    } else {
        Issue.record("expected usage, got \(result)")
    }
}

@Test
func parseCompletionsRejectsUnknownSubVerb() {
    let result = CLICommands.parse(
        ["deviceterm", "completions", "uninstall", "zsh"]
    )
    if case let .usage(message) = result {
        #expect(message?.contains("install") ?? false)
    } else {
        Issue.record("expected usage, got \(result)")
    }
}

// MARK: - Script invariants (per shell)

@Test
func zshScriptCoversEveryTopLevelVerb() {
    let script = Completions.script(for: .zsh)
    for verb in Completions.topLevelVerbs {
        #expect(
            script.contains(verb),
            "zsh script missing verb '\(verb)'"
            )
    }
}

@Test
func bashScriptCoversEveryTopLevelVerb() {
    let script = Completions.script(for: .bash)
    for verb in Completions.topLevelVerbs {
        #expect(
            script.contains(verb),
            "bash script missing verb '\(verb)'"
            )
    }
}

@Test
func fishScriptCoversEveryTopLevelVerb() {
    let script = Completions.script(for: .fish)
    for verb in Completions.topLevelVerbs {
        #expect(
            script.contains(verb),
            "fish script missing verb '\(verb)'"
            )
    }
}

@Test
func everyShellCompletesHelpTopics() {
    // `deviceterm help <TAB>` has to offer the topics, or the
    // per-command pages are only discoverable by reading the list.
    for shell in [Completions.Shell.zsh, .bash, .fish] {
        let script = Completions.script(for: shell)
        for topic in Completions.helpTopics {
            #expect(
                script.contains(topic),
                "\(shell) script missing help topic '\(topic)'"
                )
        }
    }
}

@Test
func zshAndFishCarryVerbSummaries() {
    // The gloss beside each candidate is the same one-liner the command
    // list prints, so a reader meets one wording in both places. bash
    // has no description slot, so it is deliberately excluded.
    let zsh = Completions.script(for: .zsh)
    let fish = Completions.script(for: .fish)
    for (verb, description) in Completions.verbDescriptions {
        #expect(!description.isEmpty, "no summary for verb '\(verb)'")
        #expect(zsh.contains("'\(verb):\(description)'"), "zsh missing gloss for '\(verb)'")
        #expect(fish.contains("-a \(verb) -d '\(description)'"), "fish missing gloss for '\(verb)'")
    }
}

@Test
func generatedScriptsKeepSingleQuotesBalanced() {
    // A stray apostrophe in a summary produces a script that fails to
    // load at shell startup, far from the edit that caused it. Checked
    // per line because that is the scope a quote has to close in.
    for shell in [Completions.Shell.zsh, .bash, .fish] {
        let script = Completions.script(for: shell)
        for (index, line) in script.split(separator: "\n").enumerated() {
            let quotes = line.filter { $0 == "'" }.count
            #expect(
                quotes.isMultiple(of: 2),
                "\(shell) line \(index + 1) has an unbalanced quote: \(line)"
                )
        }
    }
}

@Test
func zshScriptCoversButtonAndRotateEnums() {
    let script = Completions.script(for: .zsh)
    for value in Completions.buttonValues {
        #expect(script.contains(value), "zsh missing button '\(value)'")
    }
    for value in Completions.rotateValues {
        #expect(script.contains(value), "zsh missing rotate '\(value)'")
    }
}

@Test
func bashScriptCoversButtonAndRotateEnums() {
    let script = Completions.script(for: .bash)
    for value in Completions.buttonValues {
        #expect(script.contains(value), "bash missing button '\(value)'")
    }
    for value in Completions.rotateValues {
        #expect(script.contains(value), "bash missing rotate '\(value)'")
    }
}

@Test
func fishScriptCoversButtonAndRotateEnums() {
    let script = Completions.script(for: .fish)
    for value in Completions.buttonValues {
        #expect(script.contains(value), "fish missing button '\(value)'")
    }
    for value in Completions.rotateValues {
        #expect(script.contains(value), "fish missing rotate '\(value)'")
    }
}

@Test
func zshAndBashScriptsCoverFlagsWithDashDashSyntax() {
    // zsh's `_arguments` and bash's `compgen -W` both spell flags
    // as literal `--name`. fish's `complete -l name` uses the
    // bare-name form (no `--`); pinned separately below.
    let flags = ["--duration", "--velocity", "--step", "--json"]
    for shell in [Completions.Shell.zsh, .bash] {
        let script = Completions.script(for: shell)
        for flag in flags {
            #expect(
                script.contains(flag),
                "\(shell.rawValue) script missing flag '\(flag)'"
                )
        }
    }
}

@Test
func fishScriptCoversFlagsWithCompleteLNSyntax() {
    // fish spells long flags via `complete -l <name>` (no leading
    // dashes in the script form). The user still types `--name`,
    // but the script declares it bare.
    let script = Completions.script(for: .fish)
    for flag in ["duration", "velocity", "step", "json"] {
        #expect(
            script.contains("-l \(flag)"),
            "fish script missing `-l \(flag)`"
            )
    }
}

@Test
func axReachesTheFlagListInEveryShell() {
    // Past the `ax` sub-verb position both shells have to reach the shared
    // flag list, since that is where `--step` and `--budget` live.
    let zsh = Completions.script(for: .zsh)
    #expect(zsh.contains("_deviceterm_flags"))
    // Both the `ax` branch and the catch-all reach the shared flag function.
    #expect(zsh.components(separatedBy: "_deviceterm_flags").count - 1 >= 3)

    let bash = Completions.script(for: .bash)
    // The `ax` branch returns early only at the sub-verb position, so a later
    // word falls out of the case to the shared `${flags}` completion.
    #expect(bash.contains("""
                ax)
                    if [ "${COMP_CWORD}" -eq 2 ]; then
        """))
}

@Test
func zshScriptCarriesCompdefHeader() {
    // _deviceterm scripts live in zsh's site-functions; the
    // `#compdef deviceterm` header is the load-on-tab trigger.
    let script = Completions.script(for: .zsh)
    #expect(script.hasPrefix("#compdef deviceterm"))
}

@Test
func bashScriptRegistersWithComplete() {
    let script = Completions.script(for: .bash)
    #expect(script.contains("complete -F _deviceterm deviceterm"))
}

@Test
func fishScriptDisablesFileCompletion() {
    // Without `-f`, fish offers file paths after `deviceterm <TAB>`, a
    // bad default for a verb-driven CLI.
    let script = Completions.script(for: .fish)
    #expect(script.contains("complete -c deviceterm -f"))
}

@Test
func fishScriptDocumentsTabIdReference() {
    let script = Completions.script(for: .fish)
    #expect(script.contains("tab ref (tabId / sessionId / shortId / name / current)"))
}

@Test
func zshScriptCompletesCompletionsInstallShellArg() {
    let script = Completions.script(for: .zsh)
    #expect(script.contains("'completions subcommand'"))
}

@Test
func zshScriptCompletesAxSubVerbs() {
    let script = Completions.script(for: .zsh)
    #expect(script.contains("tree"))
    #expect(script.contains("point"))
    #expect(script.contains("sweep"))
}

@Test
func zshScriptCompletesTabsSubVerbs() {
    let script = Completions.script(for: .zsh)
    #expect(script.contains("tabs subcommand"))
    #expect(script.contains("current"))
}

@Test
func scriptsCompleteDeviceNounSubVerbs() {
    // The `device` / `devices` nouns and the `device attach` sub-verb
    // must surface in every shell's completion script.
    for shell in Completions.Shell.allCases {
        let script = Completions.script(for: shell)
        #expect(script.contains("devices"), "\(shell.rawValue) missing 'devices'")
        for sub in Completions.deviceSubVerbs {
            #expect(
                script.contains(sub),
                "\(shell.rawValue) missing device sub-verb '\(sub)'"
            )
        }
    }
}

// MARK: - Install path

@Test
func defaultZshPathFallsBackToLocalShare() {
    let path = Completions.defaultInstallPath(
        for: .zsh,
        homeDir: "/home/jane",
        env: [:]
    )
    #expect(path == "/home/jane/.local/share/zsh/site-functions/_deviceterm")
}

@Test
func defaultBashPathFallsBackToLocalShare() {
    let path = Completions.defaultInstallPath(
        for: .bash,
        homeDir: "/home/jane",
        env: [:]
    )
    #expect(
        path
        == "/home/jane/.local/share/bash-completion/completions/deviceterm"
        )
}

@Test
func defaultFishPathFallsBackToConfig() {
    let path = Completions.defaultInstallPath(
        for: .fish,
        homeDir: "/home/jane",
        env: [:]
    )
    #expect(path == "/home/jane/.config/fish/completions/deviceterm.fish")
}

@Test
func defaultPathHonorsXDGDataHomeForZsh() {
    let path = Completions.defaultInstallPath(
        for: .zsh,
        homeDir: "/home/jane",
        env: ["XDG_DATA_HOME": "/custom/data"]
    )
    #expect(path == "/custom/data/zsh/site-functions/_deviceterm")
}

@Test
func defaultPathHonorsXDGDataHomeForBash() {
    let path = Completions.defaultInstallPath(
        for: .bash,
        homeDir: "/home/jane",
        env: ["XDG_DATA_HOME": "/custom/data"]
    )
    #expect(
        path
        == "/custom/data/bash-completion/completions/deviceterm"
        )
}

@Test
func defaultPathHonorsXDGConfigHomeForFish() {
    let path = Completions.defaultInstallPath(
        for: .fish,
        homeDir: "/home/jane",
        env: ["XDG_CONFIG_HOME": "/custom/config"]
    )
    #expect(path == "/custom/config/fish/completions/deviceterm.fish")
}

// MARK: - Activation hint

@Test
func zshHintReferencesFpath() {
    let path = "/Users/jane/.local/share/zsh/site-functions/_deviceterm"
    let hint = Completions.activationHint(for: .zsh, installPath: path)
    #expect(hint.contains("fpath"))
    #expect(hint.contains("compinit"))
    // Mentions the parent dir, not the file itself, since fpath holds dirs.
    #expect(hint.contains("/Users/jane/.local/share/zsh/site-functions"))
}

@Test
func bashHintReferencesSourcing() {
    let path = "/home/jane/.local/share/bash-completion/completions/deviceterm"
    let hint = Completions.activationHint(for: .bash, installPath: path)
    #expect(hint.contains("source"))
    #expect(hint.contains(path))
}

@Test
func fishHintMentionsAutoload() {
    let hint = Completions.activationHint(
        for: .fish,
        installPath: "/home/jane/.config/fish/completions/deviceterm.fish"
    )
    #expect(hint.contains("autoload"))
}
