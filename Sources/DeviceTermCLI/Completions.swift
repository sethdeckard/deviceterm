// SPDX-License-Identifier: GPL-3.0-or-later

import ArgumentParser
import DaemonProtocol
import Foundation

/// Shell-completion scripts for the CLI surface.
///
/// `script(for:)` returns the full text of a `_deviceterm` /
/// `deviceterm.fish` / bash-completion script, generated from the
/// command declarations. `completionsInstallOutcome` writes it to
/// `defaultInstallPath(for:homeDir:)` and prints the path plus
/// `activationHint(for:installPath:)` so the user knows how to enable it
/// (typical case: append a one-liner to `~/.zshrc` and re-source).
///
/// Generating from the declarations is what keeps the candidates and the
/// grammar the same thing: a verb, sub-verb, or flag the parser accepts
/// is offered because it is declared, not because a second list was kept
/// in step. What cannot be inferred is the candidates themselves. A
/// string-typed operand carries no type to enumerate, so it names its
/// values with `completion: .list`, and a live ref names a provider with
/// `completion: .custom` because its candidates depend on daemon state.
///
/// The scripts cover the happy-path shape. The parser still validates
/// every invocation, so a misspelled flag past completion lands on
/// `usage(message:)` rather than becoming a silent no-op.
public enum Completions {
    public enum Shell: String, CaseIterable, Sendable, Equatable {
        case zsh
        case bash
        case fish

        /// The generator's spelling of this shell.
        var completionShell: CompletionShell {
            switch self {
            case .zsh:
                return .zsh

            case .bash:
                return .bash

            case .fish:
                return .fish
            }
        }
    }

    // MARK: - Completion vocabulary
    //
    // The values an operand read as a string can take. A declaration
    // types these as `String` so the parser keeps its own refusal
    // wording, which leaves the candidate list to be stated here and
    // attached with `completion: .list(...)`.
    //
    // Kebab-case is the canonical completion form; the parser
    // (`parseEnumArg`) also accepts camelCase / snake_case / all-
    // lowercase, so a user who learned the camelCase shape isn't forced
    // to retype, but completion suggests the form the help text shows.

    public static let buttonValues: [String] = [
        "home",
        "lock",
        "side",
        "apple-pay",
        "siri",
        "digital-crown"
    ]

    /// Named postures only. The verb also takes a bare angle, which no
    /// completion list can enumerate.
    public static let foldValues: [String] = FoldPosture.allCases.map(\.rawValue)

    /// Both vocabularies `rotate` takes on its one positional: the four
    /// absolute orientations, then the two relative directions.
    public static let rotateValues: [String] = [
        "portrait",
        "portrait-upside-down",
        "landscape-left",
        "landscape-right",
        "left",
        "right"
    ]

    public static let waitPaneValues: [String] = [
        "booting",
        "rendering",
        "shutdown",
        "failed"
    ]

    public static let waitOrientationValues: [String] = [
        "portrait",
        "portrait-upside-down",
        "landscape-left",
        "landscape-right"
    ]

    /// The canonical `--mode` completions for the close verbs.
    ///
    /// `parseCloseMode` reads anything but `shutdown` as `detach`, so
    /// this is what gets offered rather than what gets accepted.
    public static let closeModeValues: [String] = ["detach", "shutdown"]

    /// The one condition `wait surface` takes.
    public static let surfaceConditionValues: [String] = ["quiescent"]

    /// How an accessibility needle matches.
    public static let matchValues: [String] = ["exact", "contains"]

    /// Where an accessibility selector observes from.
    public static let sourceValues: [String] = ["tree", "sweep"]

    /// Which way `wait ax` waits.
    public static let waitStateValues: [String] = ["present", "absent"]

    /// What `wait ax --print` can emit.
    public static let waitPrintValues: [String] = ["center"]

    /// What `deviceterm help <TAB>` offers: every addressable topic,
    /// commands and concepts alike, plus the sub-verb paths, a topic
    /// being resolved as a command path.
    public static var helpTopics: [String] {
        let paths = CommandTree.all.flatMap { verb in
            verb.subVerbs.map { "\(verb.name) \($0)" }
        }
        return HelpCatalog.topicNames + paths
    }

    /// `defaultInstallPath(for:homeDir:)` honors the XDG vars when
    /// they're set in the env (so users who've configured XDG
    /// directories see their preferences respected); falls back to
    /// the conventional location otherwise.
    public static func defaultInstallPath(
        for shell: Shell,
        homeDir: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        switch shell {
        case .zsh:
            let base = env["XDG_DATA_HOME"]
                ?? (homeDir as NSString).appendingPathComponent(".local/share")
            return (base as NSString)
                .appendingPathComponent("zsh/site-functions/_deviceterm")

        case .bash:
            let base = env["XDG_DATA_HOME"]
                ?? (homeDir as NSString).appendingPathComponent(".local/share")
            return (base as NSString)
                .appendingPathComponent("bash-completion/completions/deviceterm")

        case .fish:
            let base = env["XDG_CONFIG_HOME"]
                ?? (homeDir as NSString).appendingPathComponent(".config")
            return (base as NSString)
                .appendingPathComponent("fish/completions/deviceterm.fish")
        }
    }

    /// One-line hint pointing at the rc-file change that enables the
    /// just-installed script. fish autoloads from
    /// `~/.config/fish/completions/`, so it gets the simplest hint.
    public static func activationHint(
        for shell: Shell,
        installPath: String
    ) -> String {
        switch shell {
        case .zsh:
            let dir = (installPath as NSString).deletingLastPathComponent
            return "to enable, ensure `\(dir)` is on $fpath "
                + "(append `fpath+=(\(dir))` to ~/.zshrc above `compinit`) "
                + "and reload your shell"

        case .bash:
            return "to enable, source the file from your bash-completion init "
                + "(or `source \(installPath)` from ~/.bashrc)"

        case .fish:
            return "fish autoloads completions from this directory; "
                + "open a new shell to pick it up"
        }
    }

    /// The completion script for `shell`, generated from the command
    /// declarations.
    public static func script(for shell: Shell) -> String {
        DeviceTerm.completionScript(for: shell.completionShell)
    }
}
