// SPDX-License-Identifier: GPL-3.0-or-later

/// The single per-verb table for the two otherwise
/// hand-duplicated mechanical lists: a verb's value-taking flags (the
/// parser's `CLICommands.valuedFlags` grammar) and its shell-completion
/// sub-verbs (`Completions`). Adding a verb updates it in one place
/// instead of a flag switch plus four completion arrays.
///
/// This is deliberately NOT the source of truth for *which* verbs exist
/// or what they parse to; the `CLICommand` enum and the exhaustive
/// parse/dispatch switches keep the compiler enforcing that. The help
/// prose is hand-authored in `HelpCatalog`, one topic per verb, joined
/// to this table by `HelpCatalogTests` so a verb can't gain a parser
/// entry without gaining a page. The catalog only removes the
/// silent-to-omit duplication the compiler can't catch.
enum VerbCatalog {
    struct Verb {
        let name: String
        /// Flags that consume the following token as a value (as opposed
        /// to presence-only). A verb not in the catalog falls back to
        /// `["pane"]`; see `valuedFlags(for:)`.
        let valuedFlags: Set<String>
        /// Completion sub-verbs under a hierarchical verb; empty for a
        /// flat verb. Mirrors the sub-command parsers' accepted sets.
        let subVerbs: [String]

        init(_ name: String, valuedFlags: Set<String> = ["pane"], subVerbs: [String] = []) {
            self.name = name
            self.valuedFlags = valuedFlags
            self.subVerbs = subVerbs
        }
    }

    /// Ordered so `Completions.topLevelVerbs` (derived via `map(\.name)`)
    /// keeps its historical order.
    static let all: [Verb] = [
        Verb("tabs", subVerbs: ["list", "current"]),
        Verb("panes", subVerbs: ["list"]),
        Verb("devices", subVerbs: ["list"]),
        Verb("version"),
        Verb("dump-config"),
        Verb("events"),
        Verb("doctor"),
        Verb("agents"),
        Verb("help"),
        Verb("tap"),
        Verb("swipe", valuedFlags: ["pane", "duration", "hold"]),
        Verb("app-switcher"),
        Verb("long-press", valuedFlags: ["pane", "duration"]),
        Verb("pinch", valuedFlags: ["pane", "duration"]),
        Verb("button"),
        Verb("key"),
        Verb("text"),
        Verb("rotate"),
        Verb("crown", valuedFlags: ["pane", "duration", "velocity"]),
        // `step` used by `ax sweep`; harmless on tree/point.
        Verb("ax", valuedFlags: ["pane", "step"], subVerbs: ["tree", "point", "sweep"]),
        Verb("with-pane"),
        // Workspace verbs: the full set their sub-commands accept,
        // permissively shared across sub-commands (a flag not meaningful
        // to a given sub-command is silently ignored by the dispatcher,
        // matching the convention `swipe` uses for `--velocity`). `--cwd`
        // and `--cmd` carry tab/pane open startup overrides.
        Verb(
            "tab",
            valuedFlags: ["tab", "window", "mode", "cwd", "cmd", "to", "to-window", "type-delay"],
            subVerbs: [
                "open", "close", "rename", "select", "info", "move",
                "send-input", "capture", "set-protected"
            ]
        ),
        Verb(
            "pane",
            valuedFlags: ["tab", "pane", "mode", "to-tab", "cwd", "cmd"],
            subVerbs: ["open", "close", "rename", "info", "move"]
        ),
        Verb("device", subVerbs: ["attach"]),
        Verb("window", valuedFlags: ["window", "mode"], subVerbs: ["open", "close", "focus"]),
        // `--all` is presence-only; falls through as a positional token
        // and is recognized by the sub-command parser.
        Verb("windows", valuedFlags: [], subVerbs: ["list"]),
        Verb("completions", subVerbs: ["install"])
    ]

    static let byName: [String: Verb] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) }
    )

    /// The flags `verb` treats as value-taking. Unknown verbs default to
    /// `["pane"]`, preserving the parser's historical fallback.
    static func valuedFlags(for verb: String) -> Set<String> {
        byName[verb]?.valuedFlags ?? ["pane"]
    }

    /// Completion sub-verbs under `verb`; empty for a flat/unknown verb.
    static func subVerbs(of verb: String) -> [String] {
        byName[verb]?.subVerbs ?? []
    }
}
