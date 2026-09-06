# DeviceTerm App Shell Manual Checklist

This checklist covers app-shell behavior that still needs a live Simulator, a real window server, or a person choosing a
destructive outcome.

Run `make verify` for first-window construction and the Router-backed tab and window paths. Run `make test-uitest` for
real-key tab creation, terminal splits, pane focus and movement, pane close, survivor focus, and last-terminal tab close.

The `deviceterm-e2e` skill covers tab lifecycle, the status badge, close prompts dismissed with Cancel, and the quit
prompt's Keep Running path. The sections below keep the outcomes those tracks do not observe.

Run this checklist before tagging a release.

## Preconditions

- Install Xcode with at least one bootable iOS runtime. `make probe` must print `OK`.
- Run `make build`.
- Stop this checkout's app and daemon with `make kill-daemon`.
- Pick a shutdown Simulator from `xcrun simctl list devices available` and record its UDID.
- Use that disposable Simulator for every E2E scenario that needs one.

Launch the app with `make run`. Stop if it prints a `deviceterm-make: BUSY:` line.

From an agent running in an Automation Tab, invoke the `deviceterm-e2e` skill and run playbook scenarios 1, 4, 5, and 6.
Each scenario must pass before continuing with this checklist, and scenario 6 must run last because it quits DeviceTerm
with Keep Running. Relaunch this checkout with `make run`, then inspect the orphan-recovery prompt. Continue only if every
listed Simulator is a disposable test device for this run. Choose `Shut Down All` and verify that the badge disappears.
If any listed Simulator does not belong to this run, choose `Leave Running` and stop rather than continuing from a dirty
baseline. Open a normal tab for the manual checks below.

The per-tab shim intercepts `xcrun` and `simctl`. Recognized successful Simulator transitions are reported with that
terminal session's provenance.

The daemon's menu-bar item is a monochrome iPhone glyph followed by the number of DeviceTerm-owned booted Simulators.
This checklist calls it the badge.

## 1. Terminal and automatic tab labels

| # | Action | Expected |
|---|---|---|
| 1.1 | Launch DeviceTerm and use the first tab. | One tab opens with a live shell. You can type and run commands. |
| 1.2 | Run `cd /tmp`. | The tab label changes to `tmp`. |

Tab creation, selection, and titlebar reconciliation are covered by `make test-uitest` and the `deviceterm-e2e`
tab-lifecycle scenario.

## 2. Tab rename and CWD labels

| # | Action | Expected |
|---|---|---|
| 2.1 | Right-click a tab and choose **Rename Tab…**. | A sheet opens with an empty field whose placeholder is the current automatic label. |
| 2.2 | Enter `build` and confirm. | The tab label changes to `build`. |
| 2.3 | Run `cd ~` in that tab. | The label stays `build`. A CWD change does not replace a manual title. |
| 2.4 | Open Rename Tab again, clear the field, and confirm. | The label returns to the automatic CWD or OSC title. |
| 2.5 | Run `printf '\033]2;HELLO\007'; sleep 6`. | The label shows `HELLO` during the sleep, then returns to the shell's title. A bare `printf` is usually overwritten by the next prompt. |

## 3. Simulator ownership follows the tab

Open two tabs, A and B. Tab creation and selection are already covered elsewhere; the assertions here concern boot
attribution.

| # | Action | Expected |
|---|---|---|
| 3.1 | In tab A, run `xcrun simctl boot <udid>`. | A Simulator pane attaches only to tab A, transitions from booting to rendering, and shows live SpringBoard. |
| 3.2 | Switch to tab B. | Tab B has no pane for that Simulator. |
| 3.3 | Boot a second shutdown Simulator from tab A. | A second Simulator pane attaches to tab A. The badge count reaches 2. |
| 3.4 | Switch macOS between Light and Dark appearance. | The badge glyph stays monochrome and legible in both appearances. It never renders in color. |

The `deviceterm-e2e` scenario 4 checks only the badge count. It does not replace row 3.1.

## 4. Status-item shutdown menu

| # | Action | Expected |
|---|---|---|
| 4.1 | With two owned Simulators booted, click the badge. | The menu starts with a non-clickable `DeviceTerm` row and a separator. It groups both Simulators by session. Each Simulator has `Shut Down`, `Open in Simulator.app`, and `Reveal in Finder` in its submenu. `Shut Down All` follows the Simulator groups. |
| 4.2 | If both Simulators share a device name, compare their menu titles. | Each title includes a short UDID so the Simulators remain distinct. |
| 4.3 | Choose `Shut Down` from one Simulator's submenu. | That Simulator shuts down, its pane shows the shutdown overlay, and the badge decrements to 1. |
| 4.4 | Choose `Shut Down All`. | Every remaining owned Simulator shuts down and the badge disappears. |

## 5. Shutdown overlay

| # | Action | Expected |
|---|---|---|
| 5.1 | Boot a Simulator into a tab. From another shell, run `xcrun simctl shutdown <udid>`. | The pane stops rendering and shows `Simulator shut down.` with `Reboot` and `Close Pane`. |
| 5.2 | Click `Reboot`. | The same pane boots in place and reaches `rendering`. No second pane appears. |
| 5.3 | Shut it down again and click `Close Pane`. | The pane leaves the tab. The terminal remains. |

## 6. Pane resurrection

The Simulator steps need a bootable runtime. The physical-device steps need a connected, unlocked, trusted iPhone or
iPad and may be skipped when none is available.

| # | Action | Expected |
|---|---|---|
| 6.1 | Boot a Simulator into tab A, then shut it down so the overlay appears. | The pane shows the shutdown overlay. |
| 6.2 | From tab A, boot the same UDID again. | The existing pane resumes in place. No duplicate pane appears. |
| 6.3 | Shut it down, then boot the same UDID from tab B. | A new pane appears in tab B. Tab A does not resume its stale pane. |
| 6.4 | Mirror a physical device. Split the tab, place the device pane beside or above another pane, and drag the divider off center. | The device renders in its assigned leaf at the chosen size. |
| 6.5 | Unplug the device. | The pane keeps its last frame and shows the device name with `stopped mirroring. Reconnecting…`, plus `Close Pane` and no `Reboot`. The mirror may spend its retry budget before showing this state. |
| 6.6 | Reconnect and unlock the device. | The same pane resumes in its original leaf and keeps the divider position. No second pane appears. |
| 6.7 | Unplug it again and click `Close Pane` while it is reconnecting. Then reconnect it. | The pane closes, stops watching, and does not return. |

## 7. Close outcomes and saved choices

The `deviceterm-e2e` close-prompt scenario verifies both sheet shapes, their button titles, and the safe Cancel path. This
section chooses the other outcomes and checks saved suppression.

| # | Action | Expected |
|---|---|---|
| 7.1 | Boot a Simulator into a tab. Close the tab with ⌥⌘W or its `✕`, then choose `Detach (Keep Sims Running)`. | The tab closes and the Simulator keeps running. The badge remains. |
| 7.2 | Attach a Simulator again, close the tab, and choose `Shut Down Sims`. | The tab closes and the Simulator shuts down. The badge decrements. |
| 7.3 | On a later tab close, select `Don't ask again`, choose `Always`, then choose Detach. | Later closes and quits skip their Simulator prompts and keep the Simulators running. `~/.config/deviceterm/config` contains `tab-close-default = detach` and `quit-with-sims-default = keep`. Remove both lines after the check. |
| 7.4 | Boot a Simulator, focus its pane, and press ⌘W or choose **Close Pane** from its context menu. Choose `Detach (Keep Sim Running)`. | The pane closes and the Simulator keeps running. |
| 7.5 | Attach it again, close the pane, and choose `Shut Down Sim`. | The pane closes and the Simulator shuts down. |
| 7.6 | Shut a Simulator down so its pane shows the overlay, then click `Close Pane`. | The pane closes without a prompt because the Simulator is no longer running. |
| 7.7 | Boot a UDID in tab A, shut it down, boot the same UDID from tab B, then close tab A's stale pane. | No prompt appears. Tab B's Simulator keeps running. |
| 7.8 | Split a tab with no running Simulator. Close the tab, select `Don't ask again`, choose `Always`, and confirm Close. | Later multi-pane closes are silent. `~/.config/deviceterm/config` contains `tab-close-multi-pane = close`. Remove the line after the check. |
| 7.9 | With one split tab and another tab open, right-click the other tab and choose **Close Other Tabs**. | One confirmation reports how many closing tabs contain multiple panes. Cancel aborts the whole batch. |
| 7.10 | With one split tab and no running Simulator, close the window. | `Close this window?` offers Close, Cancel, and suppression for this launch or always. Cancel keeps the window and both panes. |
| 7.11 | Boot a Simulator into a tab, then choose **Close Pane** on that tab's last terminal. | The tab-close Simulator prompt appears. With the Simulator shut down, the multi-pane confirmation appears instead. Cancel keeps the tab in either case. |

A tab containing both multiple panes and an owned booted Simulator shows only the Simulator disposition prompt. The E2E
close-prompt scenario covers that precedence and the Cancel outcome.

## 8. Quit outcomes

The `deviceterm-e2e` quit scenario verifies the prompt, both button titles, and the Keep Running path. It does not cover
the suppression control.

| # | Action | Expected |
|---|---|---|
| 8.1 | With an owned Simulator booted, press ⌘Q. Select `Don't ask again`, choose `Every time I quit`, then choose `Keep Running`. | DeviceTerm quits while the Simulator, daemon, and badge remain. `~/.config/deviceterm/config` contains `quit-with-sims-default = keep` and does not gain `tab-close-default`. |
| 8.2 | Relaunch DeviceTerm, boot or reattach an owned Simulator, then press ⌘Q. | DeviceTerm quits without a prompt and keeps the Simulator running. Remove `quit-with-sims-default = keep` from the config after the check. |
| 8.3 | Relaunch, choose `Re-attach` in the orphan-recovery prompt, press ⌘Q, and choose `Shut Down All & Quit`. | The Simulator reattaches before the quit prompt appears. DeviceTerm then quits, every owned Simulator shuts down, the daemon exits when idle, and the badge disappears. |
| 8.4 | Relaunch with no owned Simulator booted, then press ⌘Q. | DeviceTerm quits without a prompt. |

## 9. Multiple windows share one daemon

| # | Action | Expected |
|---|---|---|
| 9.1 | Press ⌘N. | A second window opens with its own tab strip and shell. |
| 9.2 | Boot one Simulator in each window. | Each pane appears in the window that issued its boot. The badge counts both. |
| 9.3 | Run `./scripts/instance-guard.sh status`. | Exactly one daemon from this checkout serves both windows. |

Window creation and Router reconciliation run under `make verify`. The assertions here concern per-window Simulator
attribution and one shared daemon.

## 10. Orphan recovery after cold start

| # | Action | Expected |
|---|---|---|
| 10.1 | Boot a Simulator and quit with `Keep Running`. | DeviceTerm exits while the daemon and badge remain. |
| 10.2 | Relaunch DeviceTerm. | A recovery prompt lists the orphaned Simulator and offers `Re-attach`, `Shut Down All`, and `Leave Running`. |
| 10.3 | Choose `Re-attach`. | The first new tab opens with every listed Simulator attached as a live pane. |
| 10.4 | Repeat 10.1, relaunch, and choose `Shut Down All`. | Every listed Simulator shuts down, no pane opens, and the badge disappears. |
| 10.5 | Repeat 10.1, relaunch, and choose `Leave Running`. | The Simulators stay booted with no pane. A later relaunch offers them again. |

## Passing the checklist

A release passes this layer when every applicable row succeeds after the automated and E2E prerequisites have passed. Do
not commit a separate run log; fixes and the release commit are the record.
