# Automation Tab Manual Checklist

This checklist covers the visible Automation Tab workflow, real reconnect behavior, and live tab-cohort behavior that
the automated suites do not prove.

Run `make verify` first. It covers Router creation of automation sessions, refusal of automation-role minting over UDS,
grant enforcement and revocation over UDS, grant capability reporting, and marker-state decisions. Those assertions do
not need to be repeated manually. Its reconnect test uses a fake client, so section 3 retains the process-boundary check.

Run this checklist before a release that changes Automation Tabs, tab protection, session cohorts, or tab-scoped device
authority.

## Preconditions

- Run `make verify`.
- Stop this checkout's app and daemon with `make kill-daemon`.
- Launch with `make run`. Stop if it prints a `deviceterm-make: BUSY:` line.
- For the device-pane section, install one bootable iOS runtime and record a shutdown Simulator UDID.

## 1. Open an Automation Tab

| # | Action | Expected |
|---|---|---|
| 1.1 | Open the Shell menu. | `Open Automation Tab` is present with the ⇧⌘T shortcut. ⌘T remains New Tab. |
| 1.2 | Choose `Open Automation Tab`. | A new tab opens with a live shell. A small accent-colored wand appears immediately to the left of its title. |
| 1.3 | Hover over the wand. | The tooltip reads `Automation tab (opened from the menu)`. |
| 1.4 | Open a regular tab with ⌘T. | The regular tab has no wand. |

## 2. Automation role and live grant

| # | Action | Expected |
|---|---|---|
| 2.1 | In the Automation Tab, run `env \| grep DEVICETERM_SESSION_ROLE`. | It prints `DEVICETERM_SESSION_ROLE=automation`. |
| 2.2 | Run `deviceterm help` and `deviceterm doctor --json`. | Help reports the automation role. The JSON doctor result reports `role: automation` and, after terminal binding completes, includes `pane.sendInput` and `pane.captureText` in the complete `allowedMethods` array. Retry once if the grant is still binding. |
| 2.3 | Open a second unprotected tab and record its terminal with `pane list`. From the Automation Tab, run `deviceterm pane capture-text <terminal>`. | The command succeeds and prints that terminal pane's visible viewport. |
| 2.4 | Run the same capture from a regular tab. | It fails with `-32011` because the regular session has no live automation grant. |

The automated suites cover the lower-level trust assertions: UDS cannot mint an automation role, an ungranted session is
refused, a granted session reaches automation verbs, and revocation takes effect on the same socket.

## 3. Reconnect and regrant

| # | Action | Expected |
|---|---|---|
| 3.1 | In the working Automation Tab, run `./scripts/instance-guard.sh status` and identify the daemon row marked `mine`. Run `kill -9 <pid>` for that exact daemon, then wait for the app to reconnect. | The GUI reconnects, rebinds the terminal, and reissues the automation grant. `deviceterm doctor --json` again lists `pane.captureText`, and capturing the unprotected terminal succeeds. |

This row intentionally crosses the process boundary. The unit test for reconnect reissue calls the binding path with a
fake client and cannot replace it.

## 4. Cross-tab authority

| # | Action | Expected |
|---|---|---|
| 4.1 | From a regular tab, run `deviceterm tab close`. | The caller's own single-terminal tab closes. |
| 4.2 | Open two regular tabs. From the first, run `deviceterm tab rename <second> x`. | The command is refused with `-32011` and names `intent.automationRequired`. |
| 4.3 | Split a regular tab with `deviceterm pane split --direction right`, then run `deviceterm tab close` from one pane. | The command is refused because the tab contains two terminal sessions. |
| 4.4 | Close the split back to one terminal and retry `deviceterm tab close`. | The tab closes. |
| 4.5 | From an Automation Tab, rename another unprotected tab. | The rename succeeds. |
| 4.6 | From a regular tab, run `deviceterm pane split <other-terminal> --direction right`. | The command is refused with `-32011`. |
| 4.7 | In a split regular tab, run `deviceterm pane rename <sibling-terminal> sibling` and `deviceterm pane close <sibling-terminal>` from the first terminal. | Both commands are refused with `intent.automationRequired`; tab membership does not confer authority over a sibling terminal session. |
| 4.8 | From the sibling terminal, rename itself, then close itself while another terminal remains. | Rename and close succeed because the target session equals the caller. |
| 4.9 | From an Automation Tab, rename or close a terminal in another visible, unprotected tab. | The live grant satisfies the exact-session mutation check. |
| 4.10 | Run `deviceterm pane close <terminal> --mode detach`. | The command fails with `intent.unsupportedPane`; an explicit mode is Simulator-only. |

## 5. Tab-strip markers and relaunch

The marker-state decisions have unit coverage. These rows retain the visual and tooltip assertions. Complete this
section before booting a Simulator so quit does not present a Simulator disposition prompt.

| # | Action | Expected |
|---|---|---|
| 5.1 | Open two regular tabs. In the first, run `deviceterm tab protect`. | An accent-colored padlock appears immediately to the left of that tab's title. The other tab has no padlock. |
| 5.2 | Hover over the padlock. | The tooltip reads `Protected tab (hidden from other sessions)`. |
| 5.3 | Run `deviceterm tab unprotect`. | The receipt confirms `protected=false` and the padlock disappears after reconciliation. |
| 5.4 | Protect an Automation Tab. | The wand appears first, followed by the padlock and then the title. |
| 5.5 | Right-click that tab and choose `Unprotect Tab`. | The padlock disappears after confirmation and the wand keeps its position. A rejection raises an alert and leaves the padlock visible. |
| 5.6 | With no owned Simulator booted, quit and relaunch DeviceTerm, then open two Automation Tabs. | DeviceTerm quits without a disposition prompt. After relaunch, the menu still creates Automation Tabs. Each tab has its own session and wand, and closing one does not affect the other. |

## 6. Tab-scoped device panes

The daemon grants device-pane control to the tab cohort. These rows need a bootable Simulator.

| # | Action | Expected |
|---|---|---|
| 6.1 | Split a regular tab twice with `deviceterm pane split --direction right`. In the last terminal, run `xcrun simctl boot <udid>`. | The Simulator pane attaches to that tab. |
| 6.2 | From the booting terminal, run `deviceterm tap 0.5 0.5`. | The tap lands even though that terminal is not the tab's primary terminal. |
| 6.3 | From another terminal in the same tab, run `deviceterm pane list`, then repeat the tap. | The Simulator pane is listed and the sibling terminal can control it. |
| 6.4 | Run `deviceterm tab protect`, then run `deviceterm devices list` from a non-primary terminal in that tab. | The attached Simulator remains visible to the tab's own terminals. |
| 6.5 | Exit the shell that booted the Simulator. | The Simulator pane stays mounted and rendering. The surviving terminals can still control it. |
| 6.6 | From a sibling terminal in the same tab, rename the Simulator pane, then close it without `--mode`. | Both mutations succeed under tab ownership. The close detaches and leaves the Simulator booted. |
| 6.7 | If a physical-device pane is available, run `deviceterm pane close <device-pane> --mode detach`. | The command fails with `intent.unsupportedPane`; physical devices have no Simulator disposition mode. |

## Passing the checklist

A release passes this layer when every applicable row succeeds after `make verify` has passed. Do not commit a separate
run log; fixes and the release commit are the record.
