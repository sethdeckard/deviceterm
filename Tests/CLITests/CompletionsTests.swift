// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// `deviceterm completions install <shell>` parser + the pure
// `Completions` emitters and path resolver. `completionsInstallOutcome` handles the
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
    // verb. `CommandDispatch.run` dispatches the install (which doesn't honor
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

// MARK: - Completion callbacks

/// A transport that must never be used. A clean exit is answered from
/// the parsed value alone, so reaching the wire means the dispatch took
/// a path it should not have.
private struct UnreachableTransport: CLITransport {
    func send(_ envelope: RPCEnvelope, timeoutSeconds: Double) -> Data {
        Issue.record("a clean exit reached the transport: \(envelope.method ?? "?")")
        return Data()
    }
}

@Test
func aCleanExitPrintsToStdoutAndSucceeds() {
    // The shell reads a completion callback's candidates off stdout.
    // Rendering the answer as a usage error would put them on stderr
    // behind a usage block, where the shell cannot read them and the
    // user sees them as noise in the command line.
    //
    // Driven from the command rather than from a `---completion` argv:
    // resolving a live ref would contact the daemon, and a unit test
    // that reaches a socket depends on whichever tabs happen to be
    // open.
    let outcome = run(
        .cleanExit(text: "current\nphn001"),
        transport: UnreachableTransport(),
        output: .human
        )
    #expect(String(data: outcome.stdout, encoding: .utf8) == "current\nphn001\n")
    #expect(outcome.stderr == nil)
    #expect(outcome.exitCode == 0)
}

@Test
func generatedScriptRequestIsACleanExit() {
    let parsed = CLICommands.parse(["deviceterm", "--generate-completion-script", "zsh"])
    guard case let .cleanExit(text) = parsed else {
        Issue.record("expected .cleanExit; got \(parsed)")
        return
    }
    #expect(text.contains("#compdef deviceterm"))
}

@Test
func aParseFailureIsStillAUsageError() {
    // The two arrive the same way and are told apart by exit code, so
    // pin that a real failure did not become a clean exit.
    guard case .usage = CLICommands.parse(["deviceterm", "tap", "--nope"]) else {
        Issue.record("expected .usage for an unknown option")
        return
    }
}

// MARK: - Generated script invariants
//
// The scripts come from the command declarations, so these check that
// the generator was handed the whole tree rather than re-pinning shell
// syntax the generator owns.

/// Each shell's script, for the checks that hold across all three.
private var everyScript: [(shell: Completions.Shell, text: String)] {
    Completions.Shell.allCases.map { ($0, Completions.script(for: $0)) }
}

@Test
func everyScriptRegistersTheSymlinkName() {
    // The target builds `deviceterm-cli` and is symlinked as
    // `deviceterm`. A script registered under either other spelling
    // completes a command nobody types.
    for (shell, text) in everyScript {
        #expect(text.contains("deviceterm"), "\(shell) script does not name deviceterm")
        #expect(!text.contains("device-term"), "\(shell) script uses the derived name")
    }
}

@Test
func everyScriptCoversEveryDeclaredVerb() {
    for (shell, text) in everyScript {
        for verb in CommandTree.all.map(\.name) {
            #expect(text.contains(verb), "\(shell) script omits verb: \(verb)")
        }
    }
}

@Test
func everyScriptCoversEverySubVerb() {
    for (shell, text) in everyScript {
        for verb in CommandTree.all where !verb.subVerbs.isEmpty {
            for subVerb in verb.subVerbs {
                #expect(
                    text.contains(subVerb),
                    "\(shell) script omits \(verb.name) \(subVerb)"
                    )
            }
        }
    }
}

@Test
func everyScriptCompletesHelpTopics() {
    // Concepts and sub-verb command paths alike.
    for (shell, text) in everyScript {
        for topic in ["targeting", "tab open", "wait ax"] {
            #expect(text.contains(topic), "\(shell) script omits help topic: \(topic)")
        }
    }
}

@Test
func everyScriptCarriesTheValueVocabularies() {
    // An operand read as a string carries no type for the generator to
    // enumerate, so its candidates are attached to the declaration. A
    // verb that loses them completes nothing after the verb name.
    let vocabulary = Completions.buttonValues
        + Completions.rotateValues
        + Completions.waitPaneValues
    for (shell, text) in everyScript {
        for value in vocabulary {
            #expect(text.contains(value), "\(shell) script omits value: \(value)")
        }
    }
}

@Test
func everyScriptHooksTheRefOptions() {
    // The ref candidates are whatever is open right now, so the script
    // has to call back into the binary rather than carry a list.
    for (shell, text) in everyScript {
        #expect(
            text.contains("---completion") || text.contains("customCompletion"),
            "\(shell) script has no callback for the live refs"
            )
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
