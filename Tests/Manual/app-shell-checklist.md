# DeviceTerm App Shell Manual Checklist

The tab + sim-pane + status-item + close/quit/orphan-recovery
behaviors live in the **manual** test layer (see `AGENTS.md` →
Testing → Layers): they need a live iOS Simulator, a real window
server, and a human watching panes render. `make verify` covers
everything *except* this layer, so this checklist is the gate for the
app shell's headline behaviors. Run it end-to-end before tagging a
release.

## Preconditions

- Xcode + at least one bootable iOS runtime installed (`make probe`
  prints `OK` — if it fails, every step below will fail too).
- A clean build: `make build`.
- No leftover daemon: `pkill -f deviceterm-daemon` (the GUI lazy-spawns a
  fresh one).
- Know a device udid to boot. List them from a tab's shell with
  `xcrun simctl list devices available` and copy a *Shutdown* device's
  udid.

Launch the app with `make run` (builds + opens `DeviceTerm.app`). The shim
is symlinked into each tab's `bin/`, so `xcrun` / `simctl` inside a tab
route through DeviceTerm and tag boots with the tab's session provenance.

Throughout: the daemon's menu-bar item reads `📱 N` where N is the count
of DeviceTerm-owned booted sims. "Badge" below means that item.

---

## 1. Tab basics

| # | Action | Expected |
|---|--------|----------|
| 1.1 | Launch; observe first tab | One tab opens with a live shell; you can type and run commands. |
| 1.2 | Press ⌘T | A second tab opens with its own fresh shell (own session). |
| 1.3 | `cd` somewhere (e.g. `cd /tmp`) | The tab label updates to the directory basename (`tmp`). |
| 1.4 | Click between tabs | Selection follows the click; window title tracks the selected tab's label. |

## 2. Tab rename + CWD labels

| # | Action | Expected |
|---|--------|----------|
| 2.1 | Right-click a tab → **Rename Tab…** | A sheet prompts for a name, prefilled empty, placeholder = current auto-label. |
| 2.2 | Type `build`, confirm | Tab label becomes `build`. |
| 2.3 | `cd ~` in that tab | Label stays `build` — a manual rename is **not** clobbered by a CWD change. |
| 2.4 | Right-click → Rename → clear the field → confirm | Label reverts to automatic (CWD basename / OSC title). |
| 2.5 | Set an OSC title and hold the prompt: `printf '\033]2;HELLO\007'; sleep 6` | Label shows `HELLO` during the sleep, then reverts. (A bare `printf` is immediately overwritten — most shells re-set the title every prompt, so test it before the next prompt draws.) |

## 3. Boot a sim into a tab (the headline)

| # | Action | Expected |
|---|--------|----------|
| 3.1 | In **tab A**, run `xcrun simctl boot <udid>` | Within ~2s a simulator pane attaches **in tab A**, transitions booting → rendering, and shows live SpringBoard. |
| 3.2 | Look at the badge | Badge appears / increments to include this sim (`📱 1`). |
| 3.3 | Switch to **tab B** | Tab B has **no** sim pane — the boot attached to tab A only. |
| 3.4 | Boot a *second* udid in tab A | A second sim pane attaches in tab A; badge shows `📱 2`. |

## 4. Status-item shutdown menu

| # | Action | Expected |
|---|--------|----------|
| 4.1 | With 2 sims booted, click the badge | The menu groups both sims by session. Each sim is a top-level item with `Shut Down`, `Open in Simulator.app`, and `Reveal in Finder` in its submenu. A separator and `Shut Down All` follow the sim groups. |
| 4.2 | If both sims share a device name | Their menu titles disambiguate (`<name> — <SHORTUDID>`). |
| 4.3 | Open one sim's submenu and click `Shut Down` | That sim shuts down; its pane shows the shutdown overlay; badge decrements to `📱 1`. |
| 4.4 | Click the badge → `Shut Down All` | Remaining sim(s) shut down; badge disappears (count 0 → item hidden). |

## 5. Pane shutdown overlay + Reboot/Close

| # | Action | Expected |
|---|--------|----------|
| 5.1 | Boot a sim into a tab (pane rendering). From another shell run `xcrun simctl shutdown <udid>` | The pane stops rendering and shows an overlay: *"Simulator shut down."* with `[Reboot]` and `[Close Pane]`. |
| 5.2 | Click `[Reboot]` | The same pane boots in place (booting → rendering); no second pane spawns. |
| 5.3 | Shut the sim down again; click `[Close Pane]` | The pane is removed from the tab; the terminal remains. |

## 6. Auto-resurrect

| # | Action | Expected |
|---|--------|----------|
| 6.1 | Boot a sim into tab A; then `xcrun simctl shutdown <udid>` so the pane is in the shutdown overlay | Pane shows the shutdown overlay. |
| 6.2 | From **tab A's** shell, `xcrun simctl boot <udid>` (same udid) | The **existing** shutdown-state pane resurrects in place — no duplicate pane. |
| 6.3 | Boot the same udid from **tab B** instead (after shutting down) | A new pane appears in **tab B** (provenance is per-session); tab A does not resurrect. |

## 7. Tab-close prompt + don't-ask-again

| # | Action | Expected |
|---|--------|----------|
| 7.1 | Boot a sim into a tab. Close it (⌥⌘W or the `✕`) | Prompt: *Close this tab?* with `Detach (Keep Sims Running)` / `Shut Down Sims` / `Cancel` + a "Don't ask again" checkbox. **⌥⌘W, not ⌘W:** ⌘W closes the focused pane, so with the sim pane focused it detaches the mirror and raises no prompt. |
| 7.2 | Choose **Detach** | Tab closes; the sim keeps running; badge still shows it. |
| 7.3 | Re-attach (boot/open) a sim in a tab; close again, choose **Shut Down Sims** | Tab closes; the sim shuts down; badge decrements. |
| 7.4 | Tick "Don't ask again" + Detach on a later close | Subsequent closes skip the prompt and detach. Verify `~/.config/deviceterm/config` gained `tab-close-default = detach`. Remove the line to restore prompting. |
| 7.5 | Cancel on the prompt | The tab stays open, unchanged. |

## 8. ⌘Q quit prompt

| # | Action | Expected |
|---|--------|----------|
| 8.1 | With ≥1 sim booted, press ⌘Q | Prompt: *Quit DeviceTerm?* with `Keep Running` / `Shut Down All & Quit` + "Don't ask again". |
| 8.2 | Choose **Keep Running** | App quits; daemon stays alive holding the sim; badge remains. Relaunch shows the orphan re-attach sheet (§10). |
| 8.3 | Quit again (boot a sim first) and choose **Shut Down All & Quit** | App quits; all owned sims shut down; daemon idle-exits; badge gone. |
| 8.4 | ⌘Q with **no** sims booted | No prompt; the app quits immediately. |

## 9. Multi-window on one daemon

| # | Action | Expected |
|---|--------|----------|
| 9.1 | Press ⌘N | A second window opens with its own tab strip and shell. |
| 9.2 | Boot a sim in window 1; boot another in window 2 | Each pane appears in its own window; badge counts both. |
| 9.3 | Confirm a single daemon | `pgrep -f deviceterm-daemon` lists exactly one pid serving both windows. |

## 10. Orphan re-attach on cold start

| # | Action | Expected |
|---|--------|----------|
| 10.1 | Boot a sim; quit with **Keep Running** (§8.2) so the sim is orphaned | Daemon still holds the sim (badge visible). |
| 10.2 | Relaunch the app | A recovery prompt lists the orphaned sim(s) and offers **Re-attach**, **Shut Down All**, and **Leave Running**. |
| 10.3 | Choose **Re-attach** | The first new tab opens with every listed sim re-attached as a live pane. |
| 10.4 | Repeat 10.1, then on relaunch choose **Shut Down All** | Every listed orphan shuts down; no pane opens; the badge clears. |
| 10.5 | Repeat 10.1, then on relaunch choose **Leave Running** | The sims stay booted with no pane. Relaunching offers them again. |

---

## On passing

If any step fails, fix it inline and re-run the affected section. There
is no committed run-log: the fix commits are the record. The app shell
is declared release-ready when this checklist passes clean.
