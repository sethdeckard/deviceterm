// SPDX-License-Identifier: GPL-3.0-or-later
//
// Help topics for the back-channel verbs: tabs, panes, windows, and the
// pane-targeting wrapper.
//
// This is a behavior-grouping extension, not a conformance split.

extension HelpCatalog {
    static let workspaceTopics: [HelpTopic] = [
        HelpTopic(
            "tab",
            .command(.workspace),
            summary: "Open, close, rename, move, or drive a tab",
            detail: """
              tab open [--window <ref>] [--cwd <path>] [--cmd '<cmd>']
                  Requires a live automation grant. Mint a fresh agent-role
                  tab. --window picks the host window. The default is your
                  own window, the one holding the calling tab. --cwd sets
                  the shell's startup directory (the CLI resolves relative
                  and ~-prefixed paths against its own CWD before sending).
                  --cmd is typed into the new shell after attach, so the
                  command runs once and the user stays at an interactive
                  prompt, matching the shape it would have if typed by hand.
                  Example: deviceterm tab open --window 2
                  Example: deviceterm tab open --cwd ~/projects/app --cmd 'claude'

              tab close [--tab <ref>] [--mode <detach|shutdown>]
                  Close the named tab. Default --tab is the caller's current
                  tab. Without a live automation grant this reaches only your
                  own tab, and only while it holds that tab's single terminal:
                  closing a split tab ends the other panes' sessions.
                  --mode controls what happens to any linked sims
                  (detach leaves them booted as orphans; shutdown shuts them
                  down).
                  Example: deviceterm tab close --mode shutdown

              tab rename [--tab <ref>] [<name>]
                  Apply a manual title. Omit <name> to restore the automatic
                  title (CWD / OSC / session name). Without a live automation
                  grant this reaches only a tab you own a terminal in.
                  Example: deviceterm tab rename "auth-feature"

              tab select [--tab <ref>]
                  Requires a live automation grant, including for your own
                  tab. Focus the named tab in its window.
                  Example: deviceterm tab select --tab abc123

              tab info [--tab <ref>]
                  Print a structured description of the named tab (role,
                  session, linked sim panes). --json emits the raw payload.
                  Example: deviceterm tab info

              tab move [--tab <ref>] [--to <index>] [--to-window <ref>]
                  Requires a live automation grant, including for your own
                  tab: a reorder can shift other tabs' positions, and
                  --to-window moves the tab into what may be another
                  agent's window.
                  Reorder the named tab within its window (--to <index>) or
                  move it to another window (--to-window <ref>, optionally at
                  --to <index>; default appends at the end). At least one of
                  --to / --to-window is required. Mirrors dragging a tab in
                  the strip.
                  Example: deviceterm tab move --to 0
                  Example: deviceterm tab move --tab abc123 --to-window 2

              tab set-protected <true|false> [--tab <ref>]
                  Hide the named tab from other sessions, or unhide it. A
                  protected tab and its panes drop out of every other
                  session's `tabs list` and `windows list`, can't be reached
                  by their refs, and are refused to `tab send-input` /
                  `tab capture` even from an automation tab. Your own
                  views are unchanged. Only a tab you own a terminal in can
                  be flipped. Default --tab is the caller's current tab; the
                  value takes true/false, yes/no, on/off, or 1/0.
                  Example: deviceterm tab set-protected true

              tab send-input [--tab <ref>] [--type-delay <ms>] <text>
                  Requires a live automation grant. Write <text> into the
                  resolved tab's terminal as though the user had typed it. Control
                  sequences (\\n, \\r, \\x03, …) flow through libghostty's
                  input pipeline like real keypresses. The receipt reports
                  only the byte count, never the typed text.
                  Authorization is a live automation grant, not a role.
                  Run it from a tab opened via Shell > "Open Automation Tab":
                  the GUI grants that tab's session, so the verb works from
                  inside it. From an ordinary agent tab it is refused
                  (error.scope_violation).
                  --type-delay <ms> animates the injection one character at a
                  time (for screencasts); omit it for the instant one-shot.
                  The verb returns as soon as the typing is enqueued (it does
                  not block for the animation), and concurrent paced calls to
                  one tab type out in order. Pacing is per-character, so keep
                  paced text to plain commands + a trailing newline (a
                  multi-byte escape sequence would be split across the delay).
                  The delay is capped at 1000 ms.
                  Example: deviceterm tab send-input --tab abc123 'echo hi\\n'
                  Example: deviceterm tab send-input --type-delay 45 -- 'ls -la\\n'

              tab capture [--tab <ref>]
                  Requires a live automation grant. Print the resolved tab's
                  currently-visible viewport (the rendered terminal screen) to
                  stdout. Captures the visible viewport only; there are no
                  scrollback or line-count flags. Human mode emits the
                  raw text (so `deviceterm tab capture > screen.txt` saves the
                  screen); `--json` emits a `{text}` object. Same grant-gated
                  authority as send-input: works from a tab opened via Shell >
                  "Open Automation Tab", refused from an agent tab.
                  Example: deviceterm tab capture --tab abc123 | grep error
            """
        ),
        HelpTopic(
            "tabs",
            .command(.workspace),
            summary: "List every open tab, or print your own",
            detail: """
              tabs list
                  List every open daemon session. Five tab-separated columns:
                    <marker>  <short_id>  <name>  <sessionId>  <label>
                  The marker is `*` on the caller's current tab (matches
                  $DEVICETERM_SESSION), a space otherwise. Use the short_id for
                  quick reference; sessionId is the canonical UUID.

              tabs current
                  Print the caller's own tab row (the one whose sessionId
                  matches $DEVICETERM_SESSION). Same columns as `tabs list`;
                  marker is always `*`. Errors when run outside a tab.
            """
        ),
        HelpTopic(
            "pane",
            .command(.workspace),
            summary: "Open, close, or inspect a pane",
            detail: """
              pane open --terminal [--tab <ref>] [--cwd <path>] [--cmd '<cmd>']
                  Open a fresh terminal pane alongside the tab's existing
                  panes, splitting the tab rather than opening a new one.
                  --cwd / --cmd carry the same semantics as `tab open`: a
                  startup directory plus a single command typed into the
                  shell after attach. Omitting --tab splits your own tab;
                  naming another one needs a live automation grant.
                  Example: deviceterm pane open --terminal
                  Example: deviceterm pane open --terminal --cwd ~/work --cmd 'make test'

              pane close [--pane <ref>] [--mode <detach|shutdown>]
                  Detach or shut down the named sim pane. --pane accepts a
                  shortId or paneId (UUID). --pane resolves sim panes only;
                  closing a physical-device pane is a GUI action. Without a
                  live automation grant this reaches only panes in a tab you
                  own a terminal in.
                  Example: deviceterm pane close --pane abc123

              pane info [--pane <ref>]
                  Print a structured description of the named sim pane.
                  Example: deviceterm pane info

              pane rename [--pane <ref>] [<name>]
              pane move [--pane <ref>] --to-tab <ref>
                  Not implemented; both return `intent.internalError`.
            """
        ),
        HelpTopic(
            "window",
            .command(.workspace),
            summary: "Open, close, or focus a window",
            detail: """
              window open
                  Requires a live automation grant. Mint a new window with
                  one fresh agent-role tab.
                  Example: deviceterm window open

              window close [--window <ref>] [--mode <detach|shutdown>]
                  Close the named window. Default --window is your own
                  window (the one holding the calling tab), not the human's
                  key window, so a stray `window close` can't reach across
                  to another window. A window that also holds a tab you
                  can't see is refused, as is one holding a tab you don't
                  solely own, unless you hold a live automation grant.
                  --mode mirrors `tab close`'s semantics for every tab the
                  window holds.
                  Example: deviceterm window close

              window focus [--window <ref>]
                  Requires a live automation grant, including for your own
                  window. Bring the named window forward, activating
                  DeviceTerm if another app is in front. --window current
                  is your own window (the caller's), not the human's key
                  window.
                  Example: deviceterm window focus --window 2
            """
        ),
        HelpTopic(
            "windows",
            .command(.workspace),
            summary: "List the windows you can see",
            detail: """
              windows list [--all]
                  List the windows you can see. Columns:
                    <marker>  <index>  <tabCount>  <selectedTabShortId>
                  The marker is `*` on your key window when it's visible,
                  a space otherwise. --json emits a `WindowInfoPayload`
                  array. Default: only your own window (the one containing
                  the calling tab). --all returns every window you can see,
                  the caller-visible projection: windows and tabs that
                  another session protects are omitted, and indices count
                  only the visible ones. Out-of-tab callers without --all
                  see an empty list. Boot a tab first or pass --all.
                  Example: deviceterm windows list --all
            """
        ),
        HelpTopic(
            "with-pane",
            .command(.workspace),
            summary: "Run a command with one pane pre-resolved",
            detail: """
              with-pane <ref> <cmd…>
                  `deviceterm with-pane <ref> <cmd…>` runs <cmd…>
                  with `DEVICETERM_TARGET_PANE` set to the resolved pane's key, so
                  downstream `deviceterm tap` / `swipe` / etc. inside <cmd…>
                  auto-target without needing --pane on every call.
                  Example: deviceterm with-pane phn001 bash -c 'deviceterm tap 0.5 0.5'
            """
        )
    ]
}
