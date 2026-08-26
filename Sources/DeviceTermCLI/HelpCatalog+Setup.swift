// SPDX-License-Identifier: GPL-3.0-or-later

/// Help topics for the verbs that report on the install rather than drive a
/// device: health, versions, config, event stream, shell tooling, and the
/// two documentation verbs.
///
/// This is a behavior-grouping extension, not a conformance split.
extension HelpCatalog {
    static let setupTopics: [HelpTopic] = [
        HelpTopic(
            "doctor",
            .command(.setup),
            summary: "Check env, daemon, and session health",
            detail: """
              doctor
                  Check the pieces every other verb depends on, one line per
                  axis: the session env vars, whether `xcrun` resolves to the
                  shim, the daemon socket and ping, and whether this session
                  is live and authenticates. Also prints the caller's
                  identity, its linked device panes, and the methods its
                  transport and grant admit. --json emits the same report as
                  an object. Exits 1 when any axis fails, so it works as a
                  health gate in a script; warnings alone still exit 0.
                  Example: deviceterm doctor
            """
        ),
        HelpTopic(
            "events",
            .command(.setup),
            summary: "Stream pane and device events as JSON lines",
            detail: """
              events
                  Subscribe to this session's event stream. Run it inside
                  a deviceterm tab; out-of-tab callers are rejected. Prints
                  one JSON object per line as events fire: this session's pane
                  state changes (booting / rendering / shutdown) and its
                  session close, plus device boots and shutdowns (device
                  events reach every session). Long-running; exits on daemon
                  EOF or Ctrl-C. Output is always JSON; pipe through jq.
                  Example: deviceterm events | jq 'select(.state=="rendering")'
            """
        ),
        HelpTopic(
            "version",
            .command(.setup),
            summary: "Print deviceterm, daemon, wire, and macOS versions",
            detail: """
              version
                  Print versions of deviceterm + daemon + RPC wire + macOS.
                  Use --json for a machine-readable object.
            """
        ),
        HelpTopic(
            "dump-config",
            .command(.setup),
            summary: "Print every config key with its value and source",
            detail: """
              dump-config
                  Print every recognized ~/.config/deviceterm/config key with
                  its current value and source (default or file). Warns
                  on unrecognized keys in the file. --json supported.
            """
        ),
        HelpTopic(
            "completions",
            .command(.setup),
            summary: "Install the zsh, bash, or fish completion script",
            detail: """
              completions install <zsh|bash|fish>
                  Generate the per-shell completion script and write it to
                  the conventional autoload path (zsh's site-functions, fish's
                  completions, bash's bash-completion dir). Prints the install
                  path and a one-line activation hint.
                  Example: deviceterm completions install zsh
            """
        )
    ]

    static let docsTopics: [HelpTopic] = [
        HelpTopic(
            "help",
            .command(.docs),
            summary: "Print this list, or one command page in full",
            detail: """
              help [<command>|<topic>]
                  Print the command list, or one command's reference page.
                  `deviceterm --help` and `deviceterm -h` are the same verb.
                  The concepts named at the foot of the list (targeting,
                  refs, output, troubleshooting) are addressable the same
                  way.
                  Examples:
                    deviceterm help
                    deviceterm help crown
            """
        ),
        HelpTopic(
            "agents",
            .command(.docs),
            summary: "Workflow recipes and triage for agents",
            detail: """
              agents
                  Print the workflow + triage guide: how a device pane
                  actually attaches to a tab, recipes for the common
                  automation shapes, where the env vars live, and the
                  permission model behind the errors this CLI returns.
                  Organized by task rather than by verb, so it complements
                  the per-command pages instead of repeating them.
                  Example: deviceterm agents
            """
        )
    ]
}
