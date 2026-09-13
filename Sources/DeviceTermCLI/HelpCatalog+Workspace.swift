// SPDX-License-Identifier: GPL-3.0-or-later

/// Help topics for the public workspace nouns: windows, tabs, and panes, plus
/// the pane-targeting wrapper.
///
/// This is a behavior-grouping extension, not a conformance split.
extension HelpCatalog {
    static let workspaceTopics: [HelpTopic] = [
        HelpTopic(
            "window",
            .command(.workspace),
            summary: "List, inspect, or change windows",
            detail: """
              A window contains tab workspaces. Window refs accept a full UUID,
              exact short ID, exact unique name, or unique full-UUID prefix.
              Names match exactly, never by prefix. The one-based index printed
              by `window list` is display metadata, not a reference. Omitted
              refs mean the caller's own window.

              window list [--all]
                  List the caller's window. --all lists every caller-visible
                  window. Human rows are:
                    <marker>  <shortId>  <name>  <tabCount>  <selectedTabId>
                  `*` marks the caller's current window. --json emits complete
                  WorkspaceWindow objects from the GUI's live projection.

              window show [<window>]
                  Show one window and its caller-visible tabs. --json emits
                  `{window, tabs}`.

              window open
                  Requires a live automation grant. Open a window, its first
                  tab, and that tab's initial terminal pane. The command waits
                  for the terminal session ID and returns all three committed
                  objects in one receipt; it does not wait for shell readiness.

              window focus [<window>]
                  Requires a live automation grant. Raise the window and return
                  its committed window, selected tab, and focused pane state.

              window close [<window>] [--mode <detach|shutdown>]
                  Close the window and all its tabs. detach leaves linked
                  Simulators booted; shutdown also shuts them down. The receipt
                  carries the closed window object and selected mode.
            """
        ),
        HelpTopic(
            "tab",
            .command(.workspace),
            summary: "List, inspect, or change tab workspaces",
            detail: """
              A tab is the workspace: it owns a pane layout containing terminal,
              Simulator, and physical-device panes. Tab refs accept an exact
              short ID, full UUID, exact unique name, or unique full-UUID prefix.
              Names match exactly, never by prefix. Omitted refs mean the
              caller's tab.

              tab list [--window <ref> | --all]
                  List tabs in the caller's window. --window selects one window;
                  --all spans every caller-visible window. Human rows are:
                    <marker>  <shortId>  <name>  <title>  <paneCount>  <state>
                  `*` marks the caller's tab. --json emits WorkspaceTab objects.

              tab show [<tab>]
                  Show one tab, every pane in layout order, and its recursive
                  split tree. --json emits `{tab, panes, layout}`. With a live
                  automation grant, terminal details may include a live
                  working-directory snapshot as `cwd`.

              tab open [--window <ref>] [--cwd <path>] [--command '<cmd>']
                  Requires a live automation grant. Open a tab in the named or
                  caller's window. Relative and ~-prefixed working directories
                  are resolved by the CLI. --command is typed after the login
                  shell attaches. The command waits for the terminal session ID
                  and returns the committed window, tab, and terminal pane; it
                  does not wait for the shell to become ready.

                  If the tab commits but terminal session creation fails, the
                  tab remains visible with state `failed`. The command fails with
                  `intent.mutationFailed`, and JSON `error.details.committed.tab`
                  identifies the addressable tab that was retained.

              tab close [<tab>] [--mode <detach|shutdown>]
                  Close the tab. detach leaves linked Simulators booted; shutdown
                  also shuts them down. Closing a split tab requires automation
                  authority because it ends the other terminal sessions.

              tab rename [<tab>] <name>
                  Assign a unique manual name. One positional names the current
                  tab; two supply the tab ref and name. Quote a name containing
                  spaces. More than two positionals is a usage error. Pass a
                  quoted empty name to clear it, or `--` before a dashed name.

              tab focus [<tab>]
                  Requires a live automation grant. Select the tab, raise its
                  window, and return the committed focus state.

              tab move [<tab>] --window <window> [--index <n>]
                  Requires a live automation grant. Move the tab to a destination
                  window, appending unless a zero-based index is supplied. Moving
                  within the same window requires --index.

              tab protect [<tab>]
              tab unprotect [<tab>]
                  Hide a tab and all of its panes from other sessions, or make it
                  visible again. The caller's own projection is unchanged.
            """
        ),
        HelpTopic(
            "pane",
            .command(.workspace),
            summary: "List, inspect, split, or drive panes",
            detail: """
              Panes are the addressable leaves inside a tab. Pane refs accept a
              full ID, exact short ID, exact unique name, exact Simulator UDID or
              physical device ID, or unique full-ID prefix. Names match exactly,
              never by prefix. A terminal pane's ID is its session ID. Omitted
              refs mean the calling terminal pane when a command permits omission.

              With a live automation grant, terminal details may include `cwd`,
              read as a live snapshot from a verified same-user process associated
              with the terminal. The field is optional and may be absent during
              process transitions. An ungranted workspace read succeeds without
              it, including when the caller owns that terminal.

              pane list [--tab <ref>]
                  List every terminal, Simulator, and physical-device pane in
                  layout order. Human rows are:
                    <marker>  <shortId>  <kind>  <name>  <id>
                  `*` marks the caller's pane. --json emits WorkspacePane objects
                  with kind-specific details and supported capabilities.

              pane show [<pane>]
                  Show one pane, including kind, host tab, focus, capabilities,
                  and its terminal, Simulator, or physical-device details.

              pane split [<pane>] --direction <left|right|up|down>
                  Create a terminal beside the anchor pane. The command waits for
                  the new terminal session ID and returns the committed tab and
                  terminal pane. It does not wait for shell readiness.

              pane focus [<pane>]
                  Requires a live automation grant. Select and raise the pane's
                  window and tab, give the pane keyboard focus, and return the
                  committed window, tab, and pane.

              pane close [<pane>] [--mode <detach|shutdown>]
                  Close any pane kind. For a Simulator, detach leaves it booted
                  and shutdown also shuts it down. An explicit --mode is valid
                  only for a Simulator; terminal and physical-device panes fail
                  with `intent.unsupportedPane`. Closing the last terminal is
                  refused with `intent.wouldCloseTab`; use `tab close` instead.

              pane rename [<pane>] <name>
                  Assign a unique pane name. One positional names the current
                  pane; two supply the pane ref and name. Quote a name containing
                  spaces. More than two positionals is a usage error. Pass a
                  quoted empty name to clear it, or `--` before a dashed name.
                  Device-pane names stay in sync with device targeting.

              Terminal pane close and rename require the target's own session or
              a live automation grant. Simulator and physical-device panes use
              target-tab ownership or a grant.

              pane send-input <pane> [--type-delay <ms>] <text>
                  Requires a live automation grant and a terminal pane. C-style
                  escapes (\\n, \\r, \\x03, ...) are decoded. The receipt reports
                  the pane and byte count, never the text. Put `--` before text
                  beginning with `-`. A paced call is capped at 1000 ms per
                  character and returns after the input is enqueued. A word
                  beginning with - is read as a flag. Put `--` before the text
                  to send such a word literally.

              pane capture-text <pane> [--ansi]
                  Requires a live automation grant and a terminal pane. Human
                  mode prints the visible viewport as raw text; --json emits
                  `{pane, text}`. Scrollback is not included.

                  --ansi keeps the pane's SGR color and style sequences.
                  Palette colors stay as palette indexes so you apply your own
                  theme. Strip the sequences and trim trailing spaces on each
                  row to get the plain capture back.
            """
        ),
        HelpTopic(
            "with-pane",
            .command(.workspace),
            summary: "Run a command with one pane pre-resolved",
            detail: """
              with-pane <ref> <cmd...>
                  Resolve a device pane from the calling tab, then run <cmd...>
                  with DEVICETERM_TARGET_PANE set to its canonical pane ID.
                  Device-control verbs in the child can omit --pane.
                  Example: deviceterm with-pane phn001 bash -c 'deviceterm tap 0.5 0.5'
            """
        )
    ]
}
