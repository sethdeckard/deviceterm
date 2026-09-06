# Keyboard Shortcuts Manual Checklist

`make verify` checks the keybinding catalog, menu registration, responder
reachability, shortcut scope, and pane-navigation logic. Its GUI smoke test
drives Router paths but does not post real key events.

`make test-uitest` posts real keys and verifies New Tab, Split Right,
Select Pane Left, Move Pane Right, focused-pane close, survivor focus, and
last-terminal tab close.

This checklist retains the outcomes those tracks do not observe: dynamic menu
labels, additional layout shapes, device-pane routing, guest-side effects,
chordless menu actions, and libghostty arbitration.

Run it after changing `Sources/App/Keybindings/`, `MainMenu.swift`, or a
responder-chain fallback, and before a release tag.

## Preconditions

- Run `make verify`.
- Run `make test-uitest`.
- Stop this checkout's app and daemon with `make kill-daemon`.
- Launch with `make run`. Stop if any command prints a
  `deviceterm-make: BUSY:` line.
- Sections 4 through 6, row 7.4, and row 8.7 need a booted Simulator pane
  in the tab.

## 1. Close resolution

`make test-uitest` already verifies that ⌘W closes the focused pane in a
two-terminal split, preserves the tab, hands focus to the survivor, and closes
the tab when its last terminal remains.

| # | Action | Expected |
|---|---|---|
| 1.1 | With one tab and one terminal, open the Shell menu. | The first close item reads **Close Tab**, not Close Pane. |
| 1.2 | Press ⌘D to add a second terminal, then open the Shell menu. | The item now reads **Close Pane**. |
| 1.3 | Return to one terminal and press ⌥⌘W. | The tab closes regardless of what ⌘W would have done. |
| 1.4 | Create three panes, focus the middle pane, and press ⌘W. | Focus moves to a neighboring pane, not whichever pane happens to be last. |

## 2. Pane navigation and layout

The simple Split Right, Select Pane Left, and Move Pane Right paths run under
`make test-uitest`. These rows cover the remaining directions and layout
shapes.

| # | Action | Expected |
|---|---|---|
| 2.1 | Build a three-pane nested layout with ⌘D, then ⇧⌘D on one side. Press ⌘] repeatedly. | Focus cycles through every pane and wraps. |
| 2.2 | Press ⌘[ repeatedly. | Focus cycles through every pane in reverse and wraps. |
| 2.3 | Press ⌥⌘↑, ⌥⌘↓, ⌥⌘←, and ⌥⌘→ from appropriate panes. | Focus lands on the pane the visible geometry indicates. At an edge, focus stays put. |
| 2.4 | Drag a divider well off center, then repeat row 2.3. | Directional focus follows the current geometry rather than the layout's original proportions. |
| 2.5 | Focus a pane with a neighbor to its left and press ⇧⌘←. | The focused pane swaps with that neighbor and keeps focus. |
| 2.6 | Focus a pane inside a split and press ⌃⇧D. | That pane's parent split changes axis. The panes remain mounted and focus stays on the same pane. |

## 3. Tabs and windows

| # | Action | Expected |
|---|---|---|
| 3.1 | Open four tabs. Press ⌘1 through ⌘4. | Each shortcut selects the tab at that position. |
| 3.2 | Press ⌘9. | The last tab is selected, whatever the tab count. |
| 3.3 | Press ⌘5 with four tabs open. | Nothing happens and no alert sounds. |
| 3.4 | Press ⇧⌘] and ⇧⌘[ past each end of the tab strip. | Selection wraps. |
| 3.5 | Hold ⌃⇧→ so repeated events queue. | The selected tab moves one slot per event rather than moving once and stopping. |
| 3.6 | Open a second window with ⌘N, then press ⌘`. | Focus moves between the windows. This is a macOS shortcut, not a DeviceTerm binding. If it does nothing, check System Settings > Keyboard > Keyboard Shortcuts. |
| 3.7 | Choose **Window > Rename Tab…**. | The rename sheet opens for the selected tab. |
| 3.8 | Choose **Shell > Duplicate Tab**. | A new tab opens with the selected tab's role and working directory. |

The UI-test harness cannot replace rows 3.7 and 3.8. Neither action has a key
equivalent, and a successful main-menu AXPress receipt is not proof that the
menu action dispatched.

## 4. Device shortcuts follow focus

Use a tab containing both a terminal pane and a Simulator pane.

| # | Action | Expected |
|---|---|---|
| 4.1 | Focus the Simulator pane. Press ⌘←, then ⌘→. | The Simulator rotates each way. |
| 4.2 | Focus the terminal pane in the same tab. Type a line, then press ⌘← and ⌘→. | The terminal handles the shortcuts. The Simulator does not rotate. |
| 4.3 | With the terminal focused, click **Device > Rotate Left**. | The Simulator rotates. Explicit menu selection stays tab-scoped even when the shortcut is withheld. |
| 4.4 | With the terminal focused, click **Device > Home**. | The Simulator goes to the Home Screen. |
| 4.5 | Focus the Simulator pane and press ⇧⌘H, ⌘L, ⌘S, and ⌘R. | Home and Lock reach the guest, a screenshot is captured, and recording starts. Press ⌘R again to stop recording. |
| 4.6 | Focus the terminal and press ⌘S. | The terminal receives the shortcut. DeviceTerm does not capture a Simulator screenshot. |
| 4.7 | Focus a guest text field, return focus to the Simulator pane, and press ⌃⇧D. | The split axis changes and no `d` appears in the guest field. |
| 4.8 | With the guest field still active, type ordinary letters, then press the unbound chord ⌘J. | Ordinary letters reach the guest. The `j` does not. Command chords are withheld from device HID even when DeviceTerm does not bind them. |

`KeybindingCatalogTests` pins the defensive rule behind row 4.7 on both
key-down and key-up. Rows 4.7 and 4.8 retain the runtime routing checks: the
menu wins the bound press, and Command chords do not reach the guest.

## 5. Device housekeeping items

Run these with a terminal focused in a tab that also contains a Simulator
pane. The unit tests prove that the forwarding selectors exist; these rows
check their visible effects.

| # | Action | Expected |
|---|---|---|
| 5.1 | Choose **Device > Install App…**. | An open panel appears, titled for the tab's Simulator. |
| 5.2 | Choose **Device > Reveal in Finder**. | Finder reveals the Simulator’s CoreSimulator device directory. |
| 5.3 | Choose **Device > Open in Simulator.app**. | Simulator.app comes forward on that Simulator. |
| 5.4 | Choose **Device > Shut Down**. | The Simulator shuts down and its pane shows the shutdown overlay. |
| 5.5 | Open the Device menu from a tab with no device pane. | The device actions are disabled rather than appearing enabled and doing nothing. |

Row 5.4 leaves the Simulator shut down. After row 5.5, return to its pane,
click `Reboot`, and wait for it to reach `rendering` before section 6.

## 6. Splits from a device pane

| # | Action | Expected |
|---|---|---|
| 6.1 | Focus a Simulator pane and press ⌘D. | A terminal pane opens beside it. |
| 6.2 | Focus the Simulator pane and press ⇧⌘D. | A terminal pane opens below it. |
| 6.3 | Run `pwd` in the new terminal. | It uses the tab's current working directory, matching a terminal-anchored split. |

## 7. libghostty keybind arbitration

Add these lines to `~/.config/ghostty/config`, then relaunch DeviceTerm:

```text
keybind = cmd+t=new_tab
keybind = ctrl+shift+n=new_tab
```

Run the following block from an external terminal, not a DeviceTerm pane.
`make kill-daemon` terminates this checkout's app and every terminal it hosts,
so an in-app shell will not execute the remaining commands.

```sh
make kill-daemon
stderr_log="$(mktemp -t deviceterm-keybindings)"
./scripts/instance-guard.sh ensure-clear
open --stderr "$stderr_log" .build/debug/DeviceTerm.app
tail -f "$stderr_log"
```

Stop if the instance guard prints a `deviceterm-make: BUSY:` line.

Once DeviceTerm opens, return to a normal tab. Before row 7.4, reattach or boot
a Simulator and wait for its pane to reach `rendering`.

| # | Action | Expected |
|---|---|---|
| 7.1 | Press ⌘T once. | DeviceTerm opens exactly one tab. No unhandled `new_tab` diagnostic appears because DeviceTerm's menu receives the event before libghostty. |
| 7.2 | Press ⌃⇧N. | No tab opens. Stderr prints exactly `deviceterm: unhandled ghostty action: new_tab`. |
| 7.3 | Press ⌃⇧N again. | No second diagnostic appears. Reporting is once per action tag for the life of the process. |
| 7.4 | Focus a terminal in a tab containing a Simulator pane, then press ⌘←. | The scope-disabled device item lets the shortcut fall through to the terminal. |

Remove the two `keybind` lines afterward and stop the `tail` command.

The diagnostic text and once-per-tag behavior are also covered by
`GhosttyActionDispositionTests`. The manual assertions retained here prove
that real key dispatch reaches the expected side of the DeviceTerm/libghostty
boundary.

## 8. Editing and presentation

| # | Action | Expected |
|---|---|---|
| 8.1 | Select terminal text with the mouse, press ⌘C, then ⌘V. | The selection round-trips. |
| 8.2 | Press ⌘A, then ⌘C. | The whole terminal buffer copies. |
| 8.3 | Press ⌘K. | The terminal viewport clears. |
| 8.4 | Open the rename sheet, type text, and use ⌘A, ⌘C, ⌘X, and ⌘V in the field. | All four shortcuts work. The Edit menu is not terminal-only. |
| 8.5 | Focus a terminal and open the Edit menu. | **Cut** is disabled because a terminal has no editable region. |
| 8.6 | Press ⌘=, ⌘-, and ⌘0. | The terminal font grows, shrinks, and resets. |
| 8.7 | Focus a Simulator pane and press ⌥⌘A. | The accessibility inspector toggles. |
| 8.8 | Type Option-A in a terminal. | The terminal receives the keyboard layout’s Option-A character (for example, `å` on a U.S. layout), and the accessibility inspector does not toggle. |

## Passing the checklist

A release passes this layer when `make verify`, `make test-uitest`, and every
applicable manual row succeed. Record any failure as a known issue with a link.

Do not commit a separate run log. Fixes and the release commit are the record.
