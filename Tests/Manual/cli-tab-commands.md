# Workspace CLI Manual Checklist

This checklist covers the live parts of the singular workspace CLI that need
real AppKit state, terminal sessions, or a Simulator. Unit tests pin parsing,
wire shapes, reference resolution, receipts, authority, and partial failure.

Run `make verify` first. Use the `deviceterm-e2e` skill for pixel and
accessibility verification of DeviceTerm's own tab and pane chrome.

## Preconditions

- Stop this checkout with `make kill-daemon`, then launch it with `make run`.
  Stop if either command prints a `deviceterm-make: BUSY:` line.
- Open one regular tab and one Automation Tab.
- In the regular tab, confirm `deviceterm tab show --json` returns one terminal
  pane whose `id` equals `terminal.sessionId`.
- Record the Automation Tab's terminal pane ID from `deviceterm pane list`.

## 1. Tabs are workspaces and panes are leaves

| # | Action | Expected |
|---|---|---|
| 1.1 | In the regular tab, run `deviceterm pane split --direction right --json`. | The receipt contains the host tab and a new terminal pane. Its `id` equals `terminal.sessionId`; no polling was needed to discover it. |
| 1.2 | Run `deviceterm tab show --json`. | `panes` contains both terminals in visible order and `layout` is a recursive split with one leaf for each pane ID. |
| 1.3 | Run `deviceterm pane show <new-pane> --json`. | The result identifies the terminal kind, host tab, focus state, capabilities, CWD, and session ID. |
| 1.4 | Run `deviceterm pane rename <new-pane> "test runner"`, then address it as `"test runner"` with `pane show`. | The committed pane receipt and subsequent read carry the stable name. |
| 1.5 | Close the new pane, then try to close the remaining terminal with `deviceterm pane close`. | The first close succeeds. The second is refused with `intent.wouldCloseTab`; `tab close` is the explicit workspace-removal command. |

## 2. Tab creation returns an addressable terminal

Run this section from the Automation Tab.

| # | Action | Expected |
|---|---|---|
| 2.1 | Run `deviceterm tab open --cwd "$PWD" --json`. | One receipt contains the committed window, tab, and initial terminal pane. The pane ID equals its session ID. |
| 2.2 | Immediately run `deviceterm pane show <receipt-pane-id> --json`. | The pane resolves without polling `pane list`. Shell attachment may still be pending; the creation receipt promises a session ID, not shell readiness. |
| 2.3 | Run `deviceterm tab rename <new-tab> api-work`, then `deviceterm tab focus api-work`. | Both receipts return the committed tab. The named tab becomes selected and its window becomes key. |
| 2.4 | Run `deviceterm tab list --json`. | One row represents each visible GUI tab, regardless of how many terminal panes it contains. |
| 2.5 | Protect the new tab from one of its own terminals, then list tabs from another tab. | `tab protect` returns `protected: true`; the protected tab and all of its panes disappear from the foreign projection. `tab unprotect` restores them. |

## 3. Simulator panes use the same hierarchy

Boot a shutdown Simulator from a terminal in the regular tab.

| # | Action | Expected |
|---|---|---|
| 3.1 | Run `deviceterm pane list`, then `deviceterm pane show <sim-pane> --json`. | The list includes terminal and Simulator leaves. The detail contains the Simulator UDID, display name, family, rendering state, orientation, dimensions, and capabilities. |
| 3.2 | Rename the Simulator pane and use the new name as `--pane` for `deviceterm tap 0.5 0.5`. | The rename receipt is committed, daemon-direct targeting sees the same name, and the tap lands. |
| 3.3 | Run `deviceterm pane close <sim-pane>`. | The pane closes and the Simulator remains booted because detach is the default. |
| 3.4 | Reattach it with `deviceterm device attach <udid>`, then run `deviceterm pane close <sim-pane> --mode shutdown`. | Attach returns the committed tab and pane. The close removes the pane and shuts down the Simulator. |

## 4. Windows contain tab workspaces

Run this section from the Automation Tab.

| # | Action | Expected |
|---|---|---|
| 4.1 | Run `deviceterm window open --json`. | A second window opens. The receipt contains its window, first tab, and initial terminal pane. |
| 4.2 | Return to the original Automation Tab and run `deviceterm window list --all --json`. Save the second window's `id` or `shortId` as `<window-ref>`. | One `WorkspaceWindow` appears per visible window with correct one-based index metadata, focus state, selected tab IDs, and tab counts. The index is not a reference. |
| 4.3 | Run `deviceterm window show <window-ref> --json`. | The detail contains the saved window and its caller-visible tab rows. |
| 4.4 | Run `deviceterm tab move <tab> --window <window-ref> --index 0`. | The receipt contains the moved tab and destination window; the GUI order matches index 0. |
| 4.5 | Run `deviceterm window focus <window-ref>`, then `deviceterm window close <window-ref> --mode detach`. | The saved window becomes key, then closes. The close receipt identifies the committed closed window and selected mode. |

## Passing the checklist

A release passes this layer when every applicable row succeeds after
`make verify` and the `deviceterm-e2e` prerequisite. Do not commit a separate
run log; fixes and the release commit are the record.
