// SPDX-License-Identifier: GPL-3.0-or-later

/// Concept help topics: the cross-cutting explanations that belong to no
/// single verb. Reachable as `deviceterm help <topic>` and named at the
/// foot of the overview, but they take no overview line of their own.
///
/// This is a behavior-grouping extension, not a conformance split.
extension HelpCatalog {
    /// What raw window, tab, and pane refs accept on workspace verbs.
    /// Both the `refs` topic and the workspace group note render this,
    /// so the grammar can't drift apart.
    static let refsLegend = """
      Workspace refs are raw strings resolved case-insensitively against the
      GUI's live projection:
        <window>  exact short ID | exact full UUID | exact unique name |
                  unique full-UUID prefix
        <tab>     exact short ID | exact full UUID | exact unique name |
                  unique full-UUID prefix
        <pane>    exact short ID | exact full ID | exact unique name |
                  exact device key | unique full-ID prefix

      Names match exactly, never by prefix. A window's one-based index is
      display-order metadata from `window list`, not a reference.

      Window and tab short IDs are the first six lowercase hexadecimal
      characters of their UUIDs. Pane short IDs are six lowercase Crockford
      base32 characters minted for the terminal session or device pane. A
      terminal pane's full ID is its session ID.

      Omitted refs and `current` select the object containing the calling
      terminal. For a pane, that is the calling terminal pane, not the pane the
      person most recently focused. `--window` and `--tab` accept the same refs
      when they scope a list or choose a destination.

      Input and AX commands take a wider --pane. See
      `deviceterm help targeting`.
    """

    /// Appended to every page whose verb drives a device pane. A reader
    /// who lands straight on `deviceterm help tap` has not seen the
    /// command list's usage line, so this is where they learn the
    /// selector exists at all.
    static let paneTargetNote = """
      These commands drive a device pane in your tab, resolved automatically
      when the tab shows one. Pass --pane <ref> when it shows more than one.
      See `deviceterm help targeting`.
    """

    static let conceptTopics: [HelpTopic] = [
        HelpTopic(
            "targeting",
            .concept,
            summary: "How a command picks which device pane to drive",
            detail: """
              This CLI runs inside a deviceterm tab and drives the tab's
              device panes: touch, hardware buttons, keyboard, rotation,
              watchOS Digital Crown, and accessibility inspection. Every
              terminal in the tab reaches them, whichever terminal booted or
              attached the device; a pane in another tab is not yours to
              drive.

              All input + AX commands resolve a device pane automatically when
              the tab shows one. Pass --pane <ref> when it shows more than
              one device pane; the CLI lists the candidates (with a type
              column) if it can't disambiguate. <ref> resolves a shortId,
              name, sim UDID, physical deviceId, or paneId prefix.
            """
        ),
        HelpTopic(
            "refs",
            .concept,
            summary: "How workspace commands resolve object references",
            detail: refsLegend
        ),
        HelpTopic(
            "output",
            .concept,
            summary: "Which commands support --json, and what goes where",
            detail: """
              Data commands (lists, receipts) support `--json` for
              machine-readable output: lists become JSON arrays, receipts
              become JSON objects. The keys are not always the human
              form's: `pane` splits into `paneId` and `shortId`, and a
              tap's `matches` is `matchCount`. JSON also carries fields
              the echo line has no room to quote, such as a
              selector-driven tap's `label` and `identifier`.
              Successful output goes to stdout.

              In JSON mode, typed failures also emit a newline-terminated
              JSON envelope on stdout under `error`. The human diagnostic
              stays on stderr and the exit status stays nonzero. Branch on
              `error.code`; do not parse `error.message` or stderr prose.
              Command-specific failures not yet using the typed contract
              may still produce empty stdout.

              Documentation commands (`--help`, `agents`) remain prose.
              AX commands always emit JSON: successes use their usual
              `tree` or `element` wrapper, while typed failures use the
              `error` envelope even without `--json`. `events` keeps its
              JSON Lines stream and human-readable stream errors.
            """
        ),
        HelpTopic(
            "troubleshooting",
            .concept,
            summary: "What to check when a command seems broken",
            detail: """
              Pane attachment is a precondition. If you get
              `no device pane in this tab`, boot a sim from this
              terminal with `xcrun simctl boot <UDID>`. The deviceterm shim
              intercepts the boot and creates the pane. Custom helpers that
              bypass `xcrun simctl boot` won't create a pane; claim such a
              sim with
              `deviceterm device attach <ref>`.
              Diagnostic recipes: see `deviceterm agents` (full triage guide
              including the crown / swipe / ax notes) or run
              `deviceterm doctor` (env + daemon + session health check).
            """
        )
    ]
}
