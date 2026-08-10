# Keyboard Shortcuts Manual Checklist

`KeybindingCatalogTests` is strong about the *map*: that a chord exists,
that it appears in a menu, that something in the responder chain answers
its selector. It proves nothing about what pressing the key does. The
in-process GUI smoke test covers Router paths but cannot post key events.
`make test-uitest` does post real key events and asserts the AX-visible
result: selected tab, tab count, pane identifiers, and which pane holds
focus after a move or a close.

This checklist covers what neither reaches. Mostly that means the device
pane, guest-side effects, and anything needing a booted sim. It also
means **anything driven by clicking a menu**: the harness can address a
menu item by title, but AXPress on a main-menu item returns success
without dispatching, because items are validated when their menu opens
and nothing in the harness opens one.

Run it after changing `Sources/App/Keybindings/`, `MainMenu.swift`, or
any responder-chain fallback, and before a release tag.

## Preconditions

- A clean build: `make build`.
- No leftover daemon: `pkill -f deviceterm-daemon` (the GUI lazy-spawns).
- Launch with `make run`. **Confirm the running app is the build you just
  made** — a stale process still serving the old menu is the easiest way
  to mis-read every row below.
- Sections 4 and 5 need a booted sim in the tab. Sections 1–3 and 6–7 do
  not.

---

## 1. Close resolution

| # | Action | Expected |
|---|--------|----------|
| 1.1 | One tab, one terminal. Open the Shell menu. | The first close item reads **Close Tab**, not Close Pane. |
| 1.2 | Press ⌘W. | The tab-close prompt appears (or the tab closes, if you have suppressed the prompt). |
| 1.3 | Split with ⌘D so the tab holds two terminals. Open the Shell menu. | The item now reads **Close Pane**. |
| 1.4 | Press ⌘W. | The focused pane closes. The tab survives. Focus lands on a surviving pane — type something to confirm it takes keys. |
| 1.5 | With one terminal left, press ⌥⌘W. | The tab closes regardless of what ⌘W would have done. |
| 1.6 | Three panes: ⌘D, then ⌘D again. Focus the middle one and press ⌘W. | Focus moves to a **neighbor**, not to whichever pane happens to be last. |

## 2. Pane navigation

| # | Action | Expected |
|---|--------|----------|
| 2.1 | Build a 3-pane nested layout (⌘D, then ⇧⌘D on one side). Press ⌘] repeatedly. | Focus cycles through every pane and wraps. |
| 2.2 | Press ⌘[ repeatedly. | Same cycle, in reverse. |
| 2.3 | Press ⌥⌘↑ ↓ ← → in turn. | Focus lands on the pane your eye expects. At an edge, focus stays put (no wrap). |
| 2.4 | Drag a divider well off-center, then repeat 2.3. | Same answers. Directional focus reads live geometry, not the tree's seed extents. |
| 2.5 | Press ⇧⌘← / ⇧⌘→. | The focused pane swaps with its neighbor **and focus follows it**. |

## 3. Tabs and windows

| # | Action | Expected |
|---|--------|----------|
| 3.1 | Open four tabs. Press ⌘1 through ⌘4. | Each selects the tab at that position. |
| 3.2 | Press ⌘9. | Selects the last tab, whatever the count. |
| 3.3 | Press ⌘5 with four tabs open. | Nothing happens. No beep. |
| 3.4 | Press ⇧⌘] / ⇧⌘[ past each end. | Selection wraps. |
| 3.5 | Hold ⌃⇧→ so presses queue up. | The tab walks one slot per press. It does not shift once and stop. |
| 3.6 | Open a second window (⌘N) and press ⌘\`. | Focus moves between windows. This is macOS's own shortcut; DeviceTerm binds nothing. If it does nothing, check System Settings ▸ Keyboard ▸ Keyboard Shortcuts. |
| 3.7 | **Window ▸ Rename Tab…** | The rename sheet opens on the *selected* tab. (The main-menu item carries no represented object, so this is the row that catches a regression to the right-click handler.) |
| 3.8 | **Shell ▸ Duplicate Tab** | A new tab opens with the selected tab's role and working directory. |

## 4. Device shortcuts follow focus

The highest-risk behavior in this checklist. Needs a tab holding **both**
a terminal pane and a device pane.

| # | Action | Expected |
|---|--------|----------|
| 4.1 | Focus the device pane. Press ⌘← then ⌘→. | The device rotates each way. |
| 4.2 | Focus the terminal pane in the *same* tab. Type a line, then press ⌘← / ⌘→. | The **cursor** moves (or whatever your shell binds them to). The device does not rotate. |
| 4.3 | With the terminal still focused, **click** Device ▸ Rotate Left. | The device rotates. A click is unambiguous, so the menu item stays tab-scoped even when the chord is withheld. |
| 4.4 | With the terminal focused, **click** Device ▸ Home. | The device goes home. |
| 4.5 | Focus the device pane and press ⇧⌘H, ⌘L, ⌘S, ⌘R. | Home, Lock, a screenshot, recording starts. Press ⌘R again to stop. |
| 4.6 | Focus the terminal and press ⌘S. | Reaches the terminal, not the device. Nothing is captured. |
| 4.7 | In the guest, tap into a text field (Safari's address bar, Notes). Focus the device pane and press ⌃⇧D. | The split axis flips and **no `d` appears in the field**. An enabled menu chord is consumed by the main menu before the pane's `keyDown:` runs, so it never becomes HID. |
| 4.8 | With that field still focused, type ordinary letters, then press ⌘J — a chord the catalog does not bind. | The letters reach the guest; the `j` does not. Every Command chord is withheld whether or not the catalog binds it, so a device pane can never swallow a system or app shortcut. |

**What `KeybindingCatalog.claims` is doing behind rows 4.7 and 4.8.** Both
`SimulatorContentView.keyDown` and `keyUp` consult it before forwarding to the
guest. The two edges reach it differently, and neither row isolates it:

- **Press.** The main menu matches key equivalents on key-down only, and it
  consumes the event when a matching item is *enabled*. All three catalog
  chords that lack Command (⌃⇧D, ⌃⇧←, ⌃⇧→) validate enabled unconditionally:
  `PaneControlAffordance` does not map `toggleSplitDirection`, so
  `PaneLayoutViewController`'s validator falls through to `return true`, and
  `TabStripViewController`'s returns `true` outright. So `keyDown:` never runs
  for them, and no chord reaches the disabled-item path that `claims` exists
  to cover. Every other catalog chord carries Command and short-circuits
  before `claims` on both edges.
- **Release.** Menus don't match key-ups, so the release is not consumed and
  travels the responder chain to the focused view. There `claims` returns
  **true** for ⌃⇧D and withholds it, which is why `KeyChord.matches` accepts
  both edges. Delete the guard and the guest receives a key-release with no
  matching press. What a guest does with an orphan release is not something
  this checklist measures, so 4.7 would not reliably fail.

Treat it as a defensive invariant covered by `KeybindingCatalogTests`
(`aKeyUpIsClaimedToo` pins the release edge). Rows 4.7 and 4.8 are worth
running for what they *do* show — the menu winning the press, and Command
chords never reaching the guest — but neither is direct coverage of the guard.

§7.4 is a *terminal*-focused fall-through. Different path, genuinely
reachable, and the whole point of scoping.

## 5. Device housekeeping items

Each of these reaches the device through a `PaneLayoutViewController`
forwarder when a **terminal** pane holds focus, which is the case to
check. A missing forwarder leaves the item reading enabled and doing
nothing.

| # | Action | Expected |
|---|--------|----------|
| 5.1 | Focus the terminal. Device ▸ Install App…. | The open panel appears, titled for the tab's sim. |
| 5.2 | Focus the terminal. Device ▸ Reveal in Finder. | Finder opens the sim's data directory. |
| 5.3 | Focus the terminal. Device ▸ Open in Simulator.app. | Simulator.app comes forward on that device. |
| 5.4 | Focus the terminal. Device ▸ Shut Down. | The sim shuts down and the pane shows the shutdown overlay. |
| 5.5 | On a tab with **no** device pane, open the Device menu. | Every item above is greyed out. Nothing reads enabled and then no-ops. |

## 6. Splits from a device pane

| # | Action | Expected |
|---|--------|----------|
| 6.1 | Focus a **device** pane and press ⌘D. | A new terminal pane opens beside it. |
| 6.2 | Focus the same device pane and press ⇧⌘D. | A new terminal pane opens below it. |
| 6.3 | Check the new pane's shell with `pwd`. | The tab's current working directory, the same one a terminal-anchored split would have used. |

## 7. libghostty keybind arbitration

Two chords, because one cannot show both halves: when DeviceTerm's
catalog wins, libghostty never receives the event, so there is nothing
to log.

Add to `~/.config/ghostty/config`, then relaunch:

```
keybind = cmd+t=new_tab
keybind = ctrl+shift+n=new_tab
```

| # | Action | Expected |
|---|--------|----------|
| 7.1 | Press ⌘T. | DeviceTerm opens a tab. Nothing on stderr — the event never reached libghostty. |
| 7.2 | Press ⌃⇧N. | No tab opens. stderr carries **exactly one** line naming the declined action. |
| 7.3 | Press ⌃⇧N again. | No second line. The diagnostic is one-shot per action tag. |
| 7.4 | Focus a terminal in a tab with a device pane and press ⌘←. | The scope-disabled item falls through to the surface — a third instance of 7.2's path, and the reason a disabled item must not consume its event. |

Remove the two `keybind` lines afterward.

## 8. Editing and presentation

| # | Action | Expected |
|---|--------|----------|
| 8.1 | Select terminal text with the mouse, ⌘C, then ⌘V. | The selection round-trips. |
| 8.2 | ⌘A then ⌘C. | The whole buffer copies. |
| 8.3 | ⌘K. | The viewport clears. |
| 8.4 | Open the rename sheet (Window ▸ Rename Tab…), type, and use ⌘A / ⌘C / ⌘X / ⌘V in the text field. | All four work. The Edit menu is not terminal-only. |
| 8.5 | With a terminal focused, open the Edit menu. | **Cut** is greyed out. A terminal has no editable region. |
| 8.6 | ⌘= / ⌘- / ⌘0. | Terminal font grows, shrinks, resets. |
| 8.7 | Focus a device pane, ⌥⌘A. | The AX inspector toggles. |
| 8.8 | Type Option-a in a terminal. | `å`, not an inspector toggle. Bare ⌥ belongs to the terminal. |

---

## Pass criteria

- Every row in §4 passes. That section is the checklist's highest-risk
  behavior and the one an automated test cannot reach.
- §1.4 and §1.6 pass: a close hands focus to a survivor, not into
  nowhere.
- Every other row passes or is recorded as a known issue with a link.

There is no committed run-log: the fix commits are the record.
