// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure shell-completion script emitters for the CLI
/// surface.
///
/// Each `script(for:)` returns the full text of a `_deviceterm` /
/// `deviceterm.fish` / bash-completion script. main.swift writes the
/// script to `defaultInstallPath(for:homeDir:)` and prints the path +
/// `activationHint(for:installPath:)` so the user knows how to enable
/// it (typical case: append a one-liner to `~/.zshrc` and re-source).
///
/// Coverage:
///   - every `VerbCatalog` verb and its `subVerbs`
///   - `help` topic names, from `HelpCatalog`
///   - the common flags, not the full per-verb grammar
///   - enum-valued: `button` (HardwareButton), `rotate` and `wait
///     orientation` (Orientation plus RotationDirection where accepted),
///     `wait pane` (PaneLifecycle), `wait --source`, and the shell argument
///     to `completions install`
///
/// The emitted scripts cover the happy-path shape: completion
/// candidates as the user types; the verb list is the source of
/// truth. The daemon still validates every call, so a misspelled flag
/// past completion lands the user on the parser's `usage(message:)`
/// error rather than a silent no-op.
public enum Completions {
    public enum Shell: String, CaseIterable, Sendable, Equatable {
        case zsh
        case bash
        case fish
    }

    // MARK: - Surface

    /// Top-level verbs that should appear at `deviceterm <TAB>`, in
    /// `VerbCatalog.all` order. That is the catalog's own stable
    /// ordering, not the order `deviceterm help` groups verbs into;
    /// completion candidates are filtered as the user types, so the
    /// sequence matters far less here than having every verb present
    /// from the same table that feeds the parser's flag grammar.
    public static var topLevelVerbs: [String] { VerbCatalog.all.map(\.name) }

    /// Sub-verbs surfaced under each hierarchical verb, taken from its
    /// `VerbCatalog.subVerbs` entry, which mirrors the sub-command
    /// parsers' (`parseTabSubcommand` / `parsePaneSubcommand` / …)
    /// accepted sets.
    public static var tabSubVerbs: [String] { VerbCatalog.subVerbs(of: "tab") }
    public static var paneSubVerbs: [String] { VerbCatalog.subVerbs(of: "pane") }
    public static var deviceSubVerbs: [String] { VerbCatalog.subVerbs(of: "device") }
    public static var windowSubVerbs: [String] { VerbCatalog.subVerbs(of: "window") }

    /// What `deviceterm help <TAB>` offers: every addressable help topic,
    /// commands and concepts alike.
    public static var helpTopics: [String] { HelpCatalog.topicNames }

    /// `name:description` pairs for shells that show a gloss beside each
    /// candidate. The descriptions are the same one-liners the command
    /// list prints, so a reader sees one wording in both places.
    ///
    /// `HelpCatalogTests` bars `:` and `'` from a summary, which is what
    /// keeps these safe to interpolate into a zsh single-quoted array and
    /// a fish `-d` argument. A stray quote would produce a script that
    /// fails to load at shell startup, far from the edit that caused it.
    public static var verbDescriptions: [(verb: String, description: String)] {
        VerbCatalog.all.map { verb in
            (verb.name, HelpCatalog.topic(named: verb.name)?.summary ?? "")
        }
    }

    // Kebab-case is the canonical completion form; the CLI parser
    // (`parseEnumArg`) also accepts camelCase / snake_case / all-
    // lowercase, so a user who learned the camelCase shape isn't
    // forced to retype, but completion suggests the form the
    // help text shows.
    public static let buttonValues: [String] = [
        "home",
        "lock",
        "side",
        "apple-pay",
        "siri",
        "digital-crown"
    ]

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

    // MARK: - Script emitters

    /// The sub-verb list for `verb`, space-joined for interpolation into a
    /// shell word list. Empty for a flat verb.
    private static func subVerbList(_ verb: String) -> String {
        VerbCatalog.subVerbs(of: verb).joined(separator: " ")
    }

    public static func script(for shell: Shell) -> String {
        switch shell {
        case .zsh:
            return zshScript()

        case .bash:
            return bashScript()

        case .fish:
            return fishScript()
        }
    }

    // MARK: - zsh

    private static func zshScript() -> String {
        let verbs = verbDescriptions
            .map { "'\($0.verb):\($0.description)'" }
            .joined(separator: " ")
        let topics = helpTopics.joined(separator: " ")
        let buttons = buttonValues.joined(separator: " ")
        let rotations = rotateValues.joined(separator: " ")
        let waitPanes = waitPaneValues.joined(separator: " ")
        let waitOrientations = waitOrientationValues.joined(separator: " ")
        let tabSubs = tabSubVerbs.joined(separator: " ")
        let paneSubs = paneSubVerbs.joined(separator: " ")
        let deviceSubs = deviceSubVerbs.joined(separator: " ")
        let windowSubs = windowSubVerbs.joined(separator: " ")
        let axSubs = subVerbList("ax")
        let tabsSubs = subVerbList("tabs")
        let panesSubs = subVerbList("panes")
        let devicesSubs = subVerbList("devices")
        let windowsSubs = subVerbList("windows")
        let completionsSubs = subVerbList("completions")
        let waitSubs = subVerbList("wait")
        return """
        #compdef deviceterm
        # zsh completion for deviceterm; generated by `deviceterm completions
        # install zsh`. The verb list, button/rotate enums, and flag
        # set are kept in sync with CLICommands.parse.

        _deviceterm_flags() {
            _arguments \\
                '--pane[target device pane: shortId/name/UDID/deviceId/paneId]:ref' \\
                '--duration[duration in milliseconds]:ms' \\
                '--hold[swipe end-point dwell in milliseconds]:ms' \\
                '--velocity[crown velocity]:v' \\
                '--step[ax sweep step (0..1)]:step' \\
                '--budget[ax sweep time budget in milliseconds]:ms' \\
                '--tab[tab ref]:tab' \\
                '--window[window ref]:window' \\
                '--mode[close mode]:(detach shutdown)' \\
                '--to-tab[destination tab ref]:tab' \\
                '--type-delay[send-input per-character delay in ms]:ms' \\
                '--all[include every window you can see (windows list)]' \\
                '--timeout[wait deadline in milliseconds]:ms' \\
                '--identifier[AX identifier to match]:value' \\
                '--label[AX label to match]:value' \\
                '--role[AX role to match]:value' \\
                '--source[AX observation source: tree or sweep]:(tree sweep)' \\
                '--json[machine-readable JSON output]'
        }

        _deviceterm() {
            local -a verbs
            verbs=(\(verbs))

            if (( CURRENT == 2 )); then
                _describe 'deviceterm command' verbs
                return
            fi

            case "${words[2]}" in
                help)
                    _values 'help topic' \(topics)
                    ;;
                tabs)
                    _values 'tabs subcommand' \(tabsSubs)
                    ;;
                panes)
                    _values 'panes subcommand' \(panesSubs)
                    ;;
                devices)
                    _values 'devices subcommand' \(devicesSubs)
                    ;;
                device)
                    _values 'device subcommand' \(deviceSubs)
                    ;;
                ax)
                    if (( CURRENT == 3 )); then
                        _values 'ax subcommand' \(axSubs)
                    else
                        _deviceterm_flags
                    fi
                    ;;
                wait)
                    if (( CURRENT == 3 )); then
                        _values 'wait condition' \(waitSubs)
                    elif (( CURRENT == 4 )) && [[ "${words[3]}" == pane ]]; then
                        _values 'pane state' \(waitPanes)
                    elif (( CURRENT == 4 )) && [[ "${words[3]}" == orientation ]]; then
                        _values 'orientation' \(waitOrientations)
                    else
                        _deviceterm_flags
                    fi
                    ;;
                tab)
                    _values 'tab subcommand' \(tabSubs)
                    ;;
                pane)
                    _values 'pane subcommand' \(paneSubs)
                    ;;
                window)
                    _values 'window subcommand' \(windowSubs)
                    ;;
                windows)
                    _values 'windows subcommand' \(windowsSubs)
                    ;;
                completions)
                    if (( CURRENT == 3 )); then
                        _values 'completions subcommand' \(completionsSubs)
                    elif (( CURRENT == 4 )) && [[ "${words[3]}" == install ]]; then
                        _values 'shell' zsh bash fish
                    fi
                    ;;
                button)
                    _values 'button' \(buttons)
                    ;;
                rotate)
                    _values 'orientation or direction' \(rotations)
                    ;;
                *)
                    _deviceterm_flags
                    ;;
            esac
        }

        _deviceterm "$@"
        """
    }

    // MARK: - bash

    private static func bashScript() -> String {
        let verbs = topLevelVerbs.joined(separator: " ")
        let topics = helpTopics.joined(separator: " ")
        let buttons = buttonValues.joined(separator: " ")
        let rotations = rotateValues.joined(separator: " ")
        let waitPanes = waitPaneValues.joined(separator: " ")
        let waitOrientations = waitOrientationValues.joined(separator: " ")
        let tabSubs = tabSubVerbs.joined(separator: " ")
        let paneSubs = paneSubVerbs.joined(separator: " ")
        let deviceSubs = deviceSubVerbs.joined(separator: " ")
        let windowSubs = windowSubVerbs.joined(separator: " ")
        let axSubs = subVerbList("ax")
        let tabsSubs = subVerbList("tabs")
        let panesSubs = subVerbList("panes")
        let devicesSubs = subVerbList("devices")
        let windowsSubs = subVerbList("windows")
        let completionsSubs = subVerbList("completions")
        let waitSubs = subVerbList("wait")
        let flags = [
            "--duration", "--hold", "--velocity", "--step", "--budget",
            "--timeout", "--identifier", "--label", "--role", "--source",
            "--tab", "--pane", "--window", "--mode", "--to-tab",
            "--type-delay", "--all", "--json"
        ].joined(separator: " ")
        return """
        # bash completion for deviceterm; generated by `deviceterm completions
        # install bash`. Source from your bash-completion init or
        # directly from ~/.bashrc.

        _deviceterm() {
            local cur prev verbs flags
            COMPREPLY=()
            cur="${COMP_WORDS[COMP_CWORD]}"
            prev="${COMP_WORDS[COMP_CWORD-1]}"
            verbs="\(verbs)"
            flags="\(flags)"

            if [ "${COMP_CWORD}" -eq 1 ]; then
                COMPREPLY=( $(compgen -W "${verbs}" -- "${cur}") )
                return 0
            fi

            case "${COMP_WORDS[1]}" in
                help)
                    COMPREPLY=( $(compgen -W "\(topics)" -- "${cur}") )
                    return 0
                    ;;
                tabs)
                    COMPREPLY=( $(compgen -W "\(tabsSubs)" -- "${cur}") )
                    return 0
                    ;;
                panes)
                    COMPREPLY=( $(compgen -W "\(panesSubs)" -- "${cur}") )
                    return 0
                    ;;
                devices)
                    COMPREPLY=( $(compgen -W "\(devicesSubs)" -- "${cur}") )
                    return 0
                    ;;
                device)
                    if [ "${COMP_CWORD}" -eq 2 ]; then
                        COMPREPLY=( $(compgen -W "\(deviceSubs)" -- "${cur}") )
                        return 0
                    fi
                    ;;
                ax)
                    if [ "${COMP_CWORD}" -eq 2 ]; then
                        COMPREPLY=( $(compgen -W "\(axSubs)" -- "${cur}") )
                        return 0
                    fi
                    ;;
                wait)
                    if [ "${COMP_CWORD}" -eq 2 ]; then
                        COMPREPLY=( $(compgen -W "\(waitSubs)" -- "${cur}") )
                        return 0
                    elif [ "${COMP_CWORD}" -eq 3 ] && [ "${COMP_WORDS[2]}" = "pane" ]; then
                        COMPREPLY=( $(compgen -W "\(waitPanes)" -- "${cur}") )
                        return 0
                    elif [ "${COMP_CWORD}" -eq 3 ] && [ "${COMP_WORDS[2]}" = "orientation" ]; then
                        COMPREPLY=( $(compgen -W "\(waitOrientations)" -- "${cur}") )
                        return 0
                    fi
                    ;;
                tab)
                    if [ "${COMP_CWORD}" -eq 2 ]; then
                        COMPREPLY=( $(compgen -W "\(tabSubs)" -- "${cur}") )
                        return 0
                    fi
                    ;;
                pane)
                    if [ "${COMP_CWORD}" -eq 2 ]; then
                        COMPREPLY=( $(compgen -W "\(paneSubs)" -- "${cur}") )
                        return 0
                    fi
                    ;;
                window)
                    if [ "${COMP_CWORD}" -eq 2 ]; then
                        COMPREPLY=( $(compgen -W "\(windowSubs)" -- "${cur}") )
                        return 0
                    fi
                    ;;
                windows)
                    if [ "${COMP_CWORD}" -eq 2 ]; then
                        COMPREPLY=( $(compgen -W "\(windowsSubs)" -- "${cur}") )
                        return 0
                    fi
                    ;;
                completions)
                    if [ "${COMP_CWORD}" -eq 2 ]; then
                        COMPREPLY=( $(compgen -W "\(completionsSubs)" -- "${cur}") )
                    elif [ "${COMP_CWORD}" -eq 3 ] && [ "${COMP_WORDS[2]}" = "install" ]; then
                        COMPREPLY=( $(compgen -W "zsh bash fish" -- "${cur}") )
                    fi
                    return 0
                    ;;
                button)
                    COMPREPLY=( $(compgen -W "\(buttons)" -- "${cur}") )
                    return 0
                    ;;
                rotate)
                    COMPREPLY=( $(compgen -W "\(rotations)" -- "${cur}") )
                    return 0
                    ;;
            esac

            COMPREPLY=( $(compgen -W "${flags}" -- "${cur}") )
        }

        complete -F _deviceterm deviceterm
        """
    }

    // MARK: - fish

    private static func fishScript() -> String {
        var lines: [String] = [
            "# fish completion for deviceterm; generated by `deviceterm completions",
            "# install fish`. fish autoloads files from the",
            "# completions directory; no sourcing needed.",
            "",
            "function __deviceterm_on_path",
            "    set -l expected $argv",
            "    set -l actual (commandline -opc)",
            "    set -e actual[1]",
            "    set -l filtered",
            "    for word in $actual",
            "        test \"$word\" = --json; or set -a filtered $word",
            "    end",
            "    set actual $filtered",
            "    test (count $actual) -eq (count $expected); or return 1",
            "    for index in (seq (count $expected))",
            "        test \"$actual[$index]\" = \"$expected[$index]\"; or return 1",
            "    end",
            "end",
            "",
            "complete -c deviceterm -f"
        ]
        // Top-level verbs at root position, each with the one-liner the
        // command list shows.
        for (verb, description) in verbDescriptions {
            lines.append(
                "complete -c deviceterm -n '__fish_use_subcommand' "
                + "-a \(verb) -d '\(description)'"
            )
        }
        // Help topics.
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path help' "
            + "-a '\(helpTopics.joined(separator: " "))'"
        )
        // Sub-verbs.
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path tabs' "
            + "-a '\(subVerbList("tabs"))'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path panes' "
            + "-a '\(subVerbList("panes"))'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path devices' "
            + "-a '\(subVerbList("devices"))'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path device' "
            + "-a '\(deviceSubVerbs.joined(separator: " "))'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path ax' "
            + "-a '\(subVerbList("ax"))'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path wait' "
            + "-a '\(subVerbList("wait"))'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path wait pane' "
                + "-a '\(waitPaneValues.joined(separator: " "))'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path wait orientation' "
                + "-a '\(waitOrientationValues.joined(separator: " "))'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path completions' "
            + "-a '\(subVerbList("completions"))'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path completions install' "
            + "-a 'zsh bash fish'"
        )
        // Workspace sub-verbs.
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path tab' "
            + "-a '\(tabSubVerbs.joined(separator: " "))'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path pane' "
            + "-a '\(paneSubVerbs.joined(separator: " "))'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path window' "
            + "-a '\(windowSubVerbs.joined(separator: " "))'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path windows' "
            + "-a '\(subVerbList("windows"))'"
        )
        // Enum-valued positionals.
        let buttonsList = buttonValues.joined(separator: " ")
        let rotateList = rotateValues.joined(separator: " ")
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path button' "
            + "-a '\(buttonsList)'"
        )
        lines.append(
            "complete -c deviceterm -n '__deviceterm_on_path rotate' "
            + "-a '\(rotateList)'"
        )
        // Flags.
        lines.append("complete -c deviceterm -l duration -d 'duration in milliseconds'")
        lines.append("complete -c deviceterm -l hold -d 'swipe end-point dwell in milliseconds'")
        lines.append("complete -c deviceterm -l velocity -d 'crown velocity'")
        lines.append("complete -c deviceterm -l step -d 'ax sweep step (0..1)'")
        lines.append("complete -c deviceterm -l budget -d 'ax sweep time budget in milliseconds'")
        lines.append("complete -c deviceterm -l timeout -d 'wait deadline in milliseconds'")
        lines.append("complete -c deviceterm -l identifier -d 'AX identifier to match'")
        lines.append("complete -c deviceterm -l label -d 'AX label to match'")
        lines.append("complete -c deviceterm -l role -d 'AX role to match'")
        lines.append(
            "complete -c deviceterm -l source -d 'AX observation source: tree or sweep' "
                + "-a 'tree sweep'"
        )
        lines.append("complete -c deviceterm -l tab -d 'tab ref (tabId / sessionId / shortId / name / current)'")
        lines.append(
            "complete -c deviceterm -l pane "
            + "-d 'target device pane (shortId/name/UDID/deviceId/paneId)'"
        )
        lines.append("complete -c deviceterm -l window -d 'window ref (index / current)'")
        lines.append("complete -c deviceterm -l mode -d 'close mode' -a 'detach shutdown'")
        lines.append("complete -c deviceterm -l to-tab -d 'destination tab ref'")
        lines.append(
            "complete -c deviceterm -l type-delay -d 'send-input per-character delay in ms'"
        )
        lines.append(
            "complete -c deviceterm -l all "
            + "-d 'windows list, include every window you can see'"
        )
        lines.append("complete -c deviceterm -l json -d 'machine-readable JSON output'")
        return lines.joined(separator: "\n") + "\n"
    }
}
