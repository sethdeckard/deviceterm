# Workspace CLI Verbs Manual Checklist

This checklist covers workspace CLI behavior that still needs a live Simulator or a visible multi-window transition.

Run `make verify` first. It covers command parsing, request and receipt shapes, reference resolution, authority decisions,
Router dispatch, GUI-unavailable errors, and expired-command rejection.

The `deviceterm-e2e` skill covers the end-to-end tab lifecycle and terminal-pane creation through CLI mutation plus
accessibility and pixel verification. Those assertions do not need to be repeated here.

## Preconditions

- Run `make verify`.
- Stop this checkout's app and daemon with `make kill-daemon`.
- Launch with `make run`. Stop if it prints a `deviceterm-make: BUSY:` line.
- Confirm `deviceterm tabs current` succeeds in the first tab.

From an agent running in an Automation Tab, invoke the `deviceterm-e2e` skill and run playbook scenarios 1 and 2. Both
scenarios must pass before continuing with this checklist. They do not boot a Simulator or quit DeviceTerm, so no orphan
recovery is expected. Open a normal tab for section 1.

## 1. Simulator pane commands

Boot a shutdown Simulator from the DeviceTerm tab before starting this section.

| # | Action | Expected |
|---|---|---|
| 1.1 | Run `deviceterm pane info`. | The output identifies the attached Simulator pane, including its pane ID, UDID, display name, family, and session. |
| 1.2 | Open another tab, return to the Simulator's tab, and run `deviceterm pane rename --pane <shortId> test-name`. | The command reaches the GUI, exits 1, and reports `intent.internalError` with `pane rename is not implemented`. |
| 1.3 | From the same tab, run `deviceterm pane move --pane <shortId> --to-tab <other-tab>`. | The command reaches the GUI, exits 1, and reports `intent.internalError` with `pane move is not implemented`. |
| 1.4 | Run `deviceterm pane close --pane <shortId>`. | The command prints `ok pane=<shortId> mode=detach`. The pane closes and the Simulator keeps running. |
| 1.5 | Reattach the Simulator, then run `deviceterm pane close --pane <shortId> --mode shutdown`. | The pane closes and the Simulator shuts down. |
| 1.6 | With no Simulator pane in the tab, run `deviceterm pane info`. | The command exits 1 with `intent.notFound` and reports that the tab has no Simulator panes. |

## 2. Window commands

Open an Automation Tab and run every command in this section from it. Opening or focusing a window requires the live
automation grant. Closing window 2 requires it because that window contains another session's tab.

| # | Action | Expected |
|---|---|---|
| 2.1 | Run `deviceterm window open`. | The command prints `ok`. A second window opens with one fresh agent-role tab. |
| 2.2 | Click the original window's Automation Tab. | The original window becomes key and window 2 remains open in the background. |
| 2.3 | Run `deviceterm windows list --all`. | One row appears for each visible window. Window 1 carries the `*` key-window marker. |
| 2.4 | Run `deviceterm windows list --all --json`. | The output is a `WindowInfoPayload` array whose window count and selected-tab identifiers match the visible windows. |
| 2.5 | Run `deviceterm window focus --window 2`. | The command prints `ok window=2`. Window 2 comes forward and becomes key. |
| 2.6 | Return to the Automation Tab and run `deviceterm window close --window 2`. | The command prints `ok window=2 mode=detach`. Window 2 closes and the original window remains. |

## Passing the checklist

A release passes this layer when every row succeeds after `make verify` and the `deviceterm-e2e` prerequisite have
passed. Do not commit a separate run log; fixes and the release commit are the record.
