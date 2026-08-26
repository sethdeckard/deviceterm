// SPDX-License-Identifier: GPL-3.0-or-later

/// Concept help topics: the cross-cutting explanations that belong to no
/// single verb. Reachable as `deviceterm help <topic>` and named at the
/// foot of the overview, but they take no overview line of their own.
///
/// This is a behavior-grouping extension, not a conformance split.
extension HelpCatalog {
    /// What `--tab` / `--pane` / `--window` accept on the workspace
    /// verbs. Both the `refs` topic and the workspace group note render
    /// this, so the columns can't drift apart.
    ///
    /// Scoped to those verbs deliberately: `parsePaneRef` encodes only
    /// `paneId` / `shortId` / `current`, while the input and AX verbs
    /// resolve a wider `--pane`. Stating the grammar without naming the
    /// verbs it covers would contradict the `targeting` topic.
    static let refsLegend = """
      Refs on the workspace verbs (tab, tabs, pane, window, windows):
        --tab     <sessionId-uuid> | <shortId> | "<name>" | current
        --pane    <paneId-uuid>    | <shortId> | current
        --window  <1-based-index>  | current

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
            summary: "What --tab, --pane, and --window accept on workspace verbs",
            detail: refsLegend
        ),
        HelpTopic(
            "output",
            .concept,
            summary: "Which commands support --json, and what goes where",
            detail: """
              Data commands (lists, receipts) support `--json` for
              machine-readable output: lists become JSON arrays, receipts
              become JSON objects with the same fields as the human form.
              Successful output goes to stdout; errors stay on stderr in
              human form regardless of mode (so `deviceterm ... --json | jq`
              works on the happy path). Documentation commands (`--help`,
              `agents`) and AX commands are unaffected: `--help` and
              `agents` are prose either way; AX already emits JSON.
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
