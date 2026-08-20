# deviceterm E2E playbook

Neutral, tool-agnostic instructions for an agent running **inside a deviceterm
tab** that has been asked to end-to-end test **deviceterm itself** — its own
AppKit GUI (window/tab/pane chrome, status item, modal prompts, device picker),
not just the CLI/daemon contract. The Claude and Codex `SKILL.md` files point
here; this is the single source of truth.

## The mental model

You have two vantage points and must combine them:

- **The `deviceterm` CLI** mutates state and reports **deterministic ground
  truth** via `--json` (tab counts, pane lifecycles, device rosters). It cannot
  see whether pixels actually rendered, what the chrome looks like, or dismiss a
  modal alert.
- **The `deviceterm-uitest` harness** is an out-of-process instrument that holds
  the Screen Recording + Accessibility grants. It captures real composited
  pixels (including the Metal sim/terminal panes), dumps deviceterm's AppKit
  accessibility tree, and drives the few GUI-only gestures with no CLI path.

**The loop, every scenario:** mutate with the CLI → assert the `--json` ground
truth → observe with the harness (capture + AX dump) → verify the GUI matches
the ground truth. A screenshot on its own is never the assertion; it is
*confirmed against* a `--json` number. That pairing is what makes a vision-based
check trustworthy.

## Invocation conventions

The two tools reach you very differently, because one ships and one doesn't:

- **CLI — `deviceterm …`.** The shipped CLI is symlinked onto every tab's
  `PATH` (as `deviceterm`), so call it by name. (Off-`PATH` only — e.g. a
  non-tab shell — fall back to `.build/debug/deviceterm-cli`, the CLI product;
  never `.build/debug/deviceterm`, which is the GUI *app* and would launch and
  block instead of printing JSON.)
- **Harness — `.agents/skills/deviceterm-e2e/helpers/uitest.sh …`.** The harness
  is a dev/test instrument, deliberately **not** on any tab's `PATH`, so `zsh:
  command not found: deviceterm-uitest` is expected. Always call it through this
  wrapper: it resolves the client (PATH → repo build product) from its own fixed
  location, so it works no matter your working directory. **Wherever a scenario
  below writes `deviceterm-uitest <verb>`, run
  `.agents/skills/deviceterm-e2e/helpers/uitest.sh <verb>` instead** — same verbs
  and flags, just the full repo-relative wrapper path (like `preflight.sh`, these
  paths are written from the repo root, your working directory).

This split is intentional: the harness holds Screen Recording + Accessibility,
capabilities kept out of the shipped product, so it lives only in the dev
checkout. The skill therefore only works from a tab in the deviceterm repo with
the harness built and its resident up (`make uitest-run`).

Write screenshots to a scratch path you control (your session scratch dir, or
`/tmp`), then read the PNG back to inspect it. Example paths below use
`/tmp/e2e-*.png`; substitute your own.

The harness client speaks to a resident harness process over a private socket.
Replies are JSON on stdout; a non-zero exit means failure. Reply shapes:

| verb | on success |
|---|---|
| `ping` | `{ok:true, resident:true, pid, tool}` |
| `doctor` | `{ok, resident, pid, bundleId, bundlePath, screenRecording, accessibility}` |
| `capture window --out <p> [--bundle-id <id>]` | `{ok:true, path, width, height, scale, bundleId}` |
| `capture status-item --out <p>` | present: `{ok:true, present:true, path, width, height, scale}`; hidden: `{ok:true, present:false}` |
| `ax dump [--bundle-id <id>]` | `{ok:true, bundleId, truncated, tree}` |
| `drive key <shortcut>` | `{ok:true, shortcut, bundleId, pid}` |
| `drive click <x> <y>` | `{ok:true, bundleId, x, y, screenX, screenY}` |
| `drive click --ax <label>` | `{ok:true, ax, bundleId}` |

`<shortcut>` is like `cmd+t`, `cmd+shift+right`, `cmd+w`. `drive click <x> <y>`
takes **window-normalized** coordinates in `0..1` (0,0 = window top-left).
`--ax <label>` presses the first accessibility element whose **title,
description, or identifier equals `<label>` exactly** — copy the labels in this
playbook verbatim; a near-miss finds nothing.

**The harness only ever captures deviceterm's own windows, never a whole
display.** `capture window` grabs the frontmost deviceterm content window —
which, when an app-modal alert is up, is the alert itself. `capture status-item`
grabs just the daemon's menu-bar badge window (or reports it absent). There is
no full-screen capture, so nothing on screen outside deviceterm is ever
photographed, and multi-monitor setups are a non-issue.

## Preflight (always first)

Run `.agents/skills/deviceterm-e2e/helpers/preflight.sh` to **check** the
environment — the agent verifies, it does not provision. It passes only when all
three hold: the harness resident is up **and** holds both TCC grants, deviceterm
is running, and deviceterm reports at least one window.

**If preflight fails, stop and hand off to the operator — do not try to fix it
yourself.** Setup is a one-time human prerequisite, not part of a run:

- **Do not run `make uitest-run` (or `make run`) yourself.** Launching the
  harness is operator setup, and the grant it needs — Screen Recording +
  Accessibility for **DeviceTermUITestHarness.app** — *cannot* be completed by an
  agent: macOS requires a human to toggle it in System Settings. Running it would
  just pop System Settings panes you can't act on.
- Instead, report exactly which gate failed and the one-line fix, then wait:
  - **No resident / missing grant** → ask the operator to run `make uitest-run`
    and complete the one-time grant (it reveals the app + opens the panes).
  - **No window** → ask them to reopen deviceterm on an unlocked display
    (a locked/asleep screen makes libghostty launch it window-less).

Only proceed to scenarios once preflight passes clean. A green preflight is your
guarantee the harness can actually observe — never run scenarios past a failing
one.

## Safety rules (do not violate)

- **You are here to observe, not to build.** This skill ends at
  observe-and-report. Nothing in it requires building, fixing, or
  provisioning, and every `make` target that rebuilds the app bundle
  (`bundle`, `test-gui`, `verify`) runs `rm -rf` on the debug bundle you are
  running inside, deleting the `bin/` symlinks that put `deviceterm` on your
  `PATH`. In particular, `CLAUDE.md`'s standing "before pushing, run `make
  verify`" does not apply while you *are* the test subject. If a scenario
  finds a bug, report it and stop — fixing it is separate work, outside the
  tab.
- **Never boot or shut down the user's simulators without explicit approval.**
  Game-dev and other work may depend on running sims. Scenarios marked
  *needs a sim* require the user to nominate a throwaway sim first.
- When a close/quit modal appears, dismiss it with the **non-destructive**
  button only: **`Cancel`** on a tab/window close, **`Keep Running`** on quit.
  **Never** press `Shut Down Sims` or `Shut Down All & Quit` against the user's
  sims.
- A `drive` briefly steals keyboard focus (it activates the target, then
  restores focus), so run scenarios on an **idle machine** — like XCUITest. A
  stray keystroke landing in the user's editor mid-drive is the failure mode.
- Capture the **status item** (menu bar) with `capture status-item`, never
  `capture window` — it is a daemon-owned `NSStatusItem` window, not part of any
  deviceterm app window.
- If `ax dump` ever returns a degenerate tree (an `AXApplication` nested inside
  itself, `truncated:true`), it is a known intermittent — re-dump; do not
  root-cause it inline. The depth/node ceilings mean it can't hang.
- A node marked `"skipped": true` was deliberately not descended into, and it
  carries no `children` key. This is **not** `truncated`, which means a limit
  ran out: re-dumping or raising a ceiling will never reveal a skipped subtree,
  so don't treat it as a flake. The dump walks from the application element, so
  the menu bar comes along; the leading menu bar item is the Apple menu, which
  macOS owns and fills, and it is skipped because a dump of the target app's UI
  has no business carrying another program's. Every other menu, deviceterm's own
  included, follows the normal traversal policy, which means it can still be cut
  short by a depth or node ceiling and marked `truncated`. Don't paste a
  system-owned subtree into a report if you find one by another route.

## The flagship cross-check

The single most trustworthy assertion the harness exists for:

> `windows list --all --json` reports `tabCount = N` for the window under test
> **⇔** the AX dump contains exactly `N` tab pills, **and** a screenshot shows
> `N` pills in the strip.

If the number, the AX tree, and the pixels disagree, that is a real bug — report
it with all three observations.

**One thing voids the ⇔: privacy.** Both CLI listings are filtered to what the
*calling* session may see; AX is not filtered at all. A tab another session
marked private is missing from your `tabCount` and your `tabs list`, while its
pill is still in the strip and still in the dump. Run the cross-check on an
all-public workspace, or expect AX to exceed the CLI by exactly the tabs you
cannot see.

**Count pills by identifier, never by role.** A pill is a node whose
`identifier` starts `deviceterm.tab.`, does not end `.close` (that is a pill's
✕), and is not `deviceterm.tab.new` (the strip's "+"). Counting by role instead
will overshoot: the "+" and every ✕ are `AXButton`, and so is a pile of window
chrome, so an app-wide `AXButton` count is a different number entirely. Scoping
to the window does not rescue it, because the chrome is in the window too.

The pill roles are worth knowing for assertions other than counting:

| element | role | identifier | notes |
|---|---|---|---|
| pill | `AXCheckBox` (subrole `AXToggle`) | `deviceterm.tab.<shortId>` | `title` is the display title; **`value` 1 = selected, 0 = not** |
| its ✕ | `AXButton` | `deviceterm.tab.<shortId>.close` | `title` is `✕`, `help` is `Close Tab` |
| the "+" | `AXButton` | `deviceterm.tab.new` | **no `title` key**; `description` and `help` both read `New Tab` |

**Read selection from `value`, not `focused`.** `focused` is `false` on every
pill including the selected one, so a `focused` predicate silently matches
nothing.

**The pill identifier is a join key, not a durable handle.** It names the tab's
*current primary* session, so closing the first terminal of a split tab changes
it. Re-read the identifier from a fresh dump rather than caching one across
mutations.

**Always pass `--all` to `windows list`.** Without it the listing is scoped to
*your* session and shows only your own tab's window, while the harness captures
and drives the frontmost window — possibly a different one entirely.

**Test with a single deviceterm window** so all three vantage points refer to the
same window and the cross-check is unambiguous. This matters because the three
observers don't agree on "which window" the way you'd expect:

- The **harness** (capture, AX dump, drive) always acts on the **AppKit frontmost
  window** — what the user is looking at.
- `windows list --all`'s **`isKey:true`** is *not* that window. It is deviceterm's
  **Router-selected** window (`workspace.selectedWindowID`), which changes only on
  navigation routes, not on plain focus changes — so after you click a different
  window, `isKey` still points at the old one.

With one window the distinction vanishes. If you must run multi-window, don't
trust `isKey` to name the captured window — reconcile by identity instead
(match `selectedTabShortId` / the tab titles you see in the capture against the
`windows list` rows), or fall back to the **workspace total** (sum `tabCount`
across all rows), which moves by the same delta no matter which window a gesture
lands in — the tactic the automated `make test-uitest` smoke uses.

## Mutations land after the CLI returns

A workspace verb returns when the GUI has **accepted** the command, not when the
change is observable everywhere. Asserting the instant the CLI exits can read
the old state and report a mismatch that was never real. How much is still
outstanding depends on the verb:

- **Route-backed mutations** (open, select, close) go through `Router.dispatch`,
  which enqueues onto a serial drain and returns immediately. The GUI acks on
  the enqueue, so the CLI can exit before the route has run at all.
- **Direct mutations**, `tab rename` among them, update the view model before
  the ack, so the GUI-side change is already made when the CLI returns. AppKit
  still has to draw it and the daemon still has to be told, so neither pixels
  nor `tabs list` is guaranteed current.

**Poll for the expected delta rather than reading once**, on whichever source
you are asserting against (`tabs list --json`, `windows list --all --json`, a
fresh `ax dump`, a fresh capture). Bound the wait, and report a timeout as a
timeout rather than as a mismatch. Size the bound to the operation instead of
reaching for a habitual number: opening a tab waits on `session.create`, whose
client-side request deadline is 15 s, so a two-second bound can fail a tab that
was going to arrive.

**Don't assume which source settles first, because it is operation-specific.**
Opening a tab creates the session *before* the GUI appends the tab, so the row
can appear in `tabs list` while the pill is not yet in the strip. Renaming runs
the other way: the pill changes first, and the daemon learns the title
afterwards. Poll each source on its own rather than treating any one of them as
the leading indicator.

A mismatch that survives polling is a finding worth reporting. A mismatch on the
first read is usually just this.

---

## Scenario library

Each scenario: **goal → mutate → assert (`--json`) → observe (harness) →
verify**. The exact CLI verbs, JSON keys, and GUI strings below are current as
of this writing; if a string here doesn't match what you observe, treat the
mismatch itself as a finding rather than papering over it.

### 1. Tab lifecycle — open / select / rename / close

- **Mutate:** `deviceterm tab open`
- **Assert:** `deviceterm tabs list --json` is an array of
  `{current, shortId?, name?, displayTitle?, sessionId, label?}` across the whole
  workspace, filtered to what your session may see; its length grew by 1.
  Separately,
  `deviceterm windows list --all --json`'s `tabCount` for the window you opened
  into grew by 1 (in the recommended single-window setup, the sole row). Treat
  these as two independent deltas, not one equality — `tabs list` is
  workspace-wide, `tabCount` is per-window.

  **They also count different things.** `tabs list` returns one row per
  caller-visible terminal *session*, `tabCount` counts caller-visible GUI
  *tabs*, and the pills show every tab in the window whether you can see it via
  the CLI or not. On an all-public workspace a split tab is therefore several
  session rows, one `tabCount`, and one pill, with all three correct. Use
  `tabCount` and the pills when you mean tabs.
- **Observe:** `deviceterm-uitest ax dump` — count tab pills by identifier
  prefix (see the flagship cross-check above);
  `deviceterm-uitest capture window --out /tmp/e2e-tabs.png` then read the PNG.
- **Verify:** the flagship cross-check holds (count matches across JSON + AX +
  pixels).
- **Rename:** `deviceterm tab rename "My Tab"` sets the GUI **manual title**
  (top of the precedence chain: manual → OSC → session name → cwd basename →
  `shell`). **Do not assert it via `tabs list --json`'s `name`**: that field is
  the daemon *session name* layer (set at `session.create` / worktree
  auto-name), which a manual rename does not touch, so it stays unchanged
  however the rename went.

  The resolved title does reach the daemon, as **`displayTitle`** on the same
  row, so it is a second opinion rather than nothing. It is not a substitute for
  AX and pixels here, because the GUI pushes it asynchronously: a read
  immediately after the rename can still show the old title. It can also be nil,
  for instance on the non-primary terminals of a split tab, whose title
  publishes under the primary's session.

  Verify through the harness instead, on **the pill for the tab you renamed**,
  whose `title` reads `My Tab`. Mind which tab that is: a bare `tab rename`
  targets the *calling shell's own* tab, because `--tab` defaults to `current`.
  The **window titlebar** shows the **selected** tab's title, so it only agrees
  when the tab you renamed is also the selected one. If you opened a tab earlier
  in this scenario, the new tab is selected and the titlebar still reads *its*
  title while the rename worked perfectly. To assert the titlebar, name the
  target explicitly with `tab rename --tab <shortId> "My Tab"`, or select the
  caller's tab first.
- **Select:** `deviceterm tab select --tab <shortId>`. **Do not assert with
  `tabs list --json`'s `current`** — that flag marks the row matching the
  *calling shell's* `DEVICETERM_SESSION`, i.e. the agent's own tab, regardless of
  which tab is selected. Assert on the **selected window** instead: `tab select`
  is a Router route, so it sets `workspace.selectedWindowID` — meaning
  `windows list --all --json`'s `isKey:true` row *is* the window holding the newly
  selected tab, and its `selectedTabShortId` should equal `<shortId>`. Confirm it
  in AX: that pill's **`value` is 1** and every other pill's is 0. Do not reach
  for `focused`, which is false on all of them.

  **GUI-only select:** `drive click --ax "deviceterm.tab.<shortId>"` selects that
  exact tab. Prefer the identifier over the title, which is the live display
  title and collides freely (several tabs in one window commonly share one).
- **GUI-only open:** `deviceterm-uitest drive key cmd+t` (New Tab), or
  `drive click --ax "deviceterm.tab.new"` to press the strip's "+" specifically.
  Both open a tab; re-assert the count grew.

  Do **not** use `drive click --ax "New Tab"` for this. That string matches the
  **Shell** menu item by title and the "+" by description, and the element search
  walks the whole application, so it presses one of them without telling you
  which. The identifier is unambiguous, and the "+" publishes no title at all, so
  the identifier is the only way to name it.
- **Close:** `deviceterm tab close --tab <shortId> --mode detach` (detach keeps
  any booted sims). Re-assert the count dropped. *If the tab booted a sim, a
  modal appears — see scenario 5.*

### 2. Pane split + rearrange

- **Mutate:** `deviceterm pane open --terminal` splits the active tab.
- **Assert:** the command's `--json` receipt is the ack
  `{ok:true, tab:"<target>"}` (`Receipt.PaneOpenTerminal`). **Do not** look for
  the new pane in `panes list --json` — that roster is the daemon's **sim/device**
  panes only (every entry carries a `udid`/`target`); App-side *terminal* panes
  never appear there, so a missing row is expected, not a failure.
- **Observe (this is the real assertion):** every pane's root view is an
  `AXGroup` whose `identifier` is `deviceterm.pane.<kind>.<key>`, one of
  `deviceterm.pane.terminal.4`, `deviceterm.pane.sim.<udid>`,
  `deviceterm.pane.device.<deviceId>`, `deviceterm.pane.pending.<n>`. Count those
  nodes in `ax dump` for the pane count, and `capture window` to see the split.
  The rendering and these nodes are the ground truth here, not a roster row.
  Count **deltas**, not absolutes: only the selected tab's panes are in the view
  hierarchy, and a second window contributes its own.
- **Which pane has focus:** a focused pane node answers `"focused": true`.
  No CLI verb exposes focus, so this is the only view of it. **`AXFocused`
  is per window, not per app:** every open window keeps its own first responder,
  so a second deviceterm window contributes a second focused pane. Assert on the
  identifier you are driving (was it focused, did focus leave it), never on
  "exactly one focused pane".
- **GUI-only split** (the CLI verb above appends; these split the *focused*
  pane, and with a device pane focused the new terminal lands beside it):
  - `deviceterm-uitest drive key cmd+d` → **Split Right**
  - `deviceterm-uitest drive key cmd+shift+d` → **Split Down**
  Each adds one pane node and focuses the new one.
- **GUI-only focus + rearrange** (no CLI equivalent; these are menu key
  equivalents):
  - `drive key cmd+]` / `cmd+[` → **Next / Previous Pane**, cycling display
    order and wrapping at both ends
  - `drive key opt+cmd+left` / `right` / `up` / `down` → **Select Pane** in that
    direction, by what is on screen; no wrap, so an arrow at the edge is a no-op
  - `drive key cmd+shift+left` / `cmd+shift+right` → **Move Pane Left / Right**
  - `drive key ctrl+shift+d` → **Toggle Split Direction** (⌃⇧D; ⇧⌘D is Split
    Down)
  After a focus key, re-dump and confirm the focused identifier changed; after a
  rearrange, re-capture and confirm the layout changed as named.
- **GUI-only close:** `drive key cmd+w` → **Close Pane**, acting on the focused
  pane, so its identifier leaves the dump while the tab stays. The item is
  titled after what it would close, and on a tab whose focused terminal is its
  last one it reads **Close Tab** and closes the tab instead, because a tab must
  keep at least one terminal. So a tab holding one terminal beside one sim has
  two panes, and ⌘W with the *terminal* focused takes the whole tab.
  `drive key opt+cmd+w` is Close Tab regardless of focus.
- Note: `pane rename` and `pane move` are daemon placeholders (they return an
  internal error today) — don't assert on them. `pane attach` was **retired**;
  use `device attach` (scenario 7).

### 3. Pending-pane lifecycle *(needs a sim — GUI-only, invisible to the CLI)*

The instant loading placeholder that swaps to a rendered pane is a pure-GUI
behavior; the CLI only sees the final lifecycle state.

- **Mutate:** attach a sim so a pane goes through pending (e.g. boot an
  **approved** throwaway sim; the shim auto-attaches it).
- **Observe (fast):** immediately `capture window` — the placeholder shows a
  large `ProgressView`, the pane label, and the text **`Connecting…`**; `ax dump`
  names that text.
- **Observe (after attach):** `capture window` again — the placeholder has
  swapped to the rendered sim pane; `deviceterm panes list --json` shows the
  pane `state` advanced (e.g. to `rendering`), and the pixels show the sim.
- **Failure variant (advanced):** if an attach fails, the pane shows
  **`Couldn't connect to <label>`** with **`Retry`** and **`Close`** buttons.
  Drive `Close` via `drive click --ax "Close"` to dismiss. Forcing a failure is
  hard to do safely; treat this variant as opportunistic.

### 4. Status item badge *(needs a sim — menu bar, daemon-owned)*

- **Mutate:** with an **approved** sim booted and owned by deviceterm.
- **Assert:** `deviceterm panes list --json` / `devices list --json` reflect the
  owned booted sim(s); count = N.
- **Observe:** `deviceterm-uitest capture status-item --out /tmp/e2e-badge.png`.
  This captures **just** the daemon's badge window (not a display), so it's
  monitor-independent. Read the PNG; it shows a **monochrome iPhone glyph
  followed by N**. The glyph is a template image, so its color tracks the menu
  bar's appearance — read the integer, not the ink.
- **Verify:** the badge integer equals N. With zero owned-booted sims the item
  is **hidden entirely** (not a glyph with `0`), and the daemon then owns no
  badge window —
  so `capture status-item` returns **`{ok:true, present:false}`** with no PNG.
  That `present:false` *is* the hidden-at-zero confirmation; a present badge
  returns `present:true` with the image.

### 5. Close-tab modal *(needs a sim — GUI-only; only an out-of-process driver can dismiss it)*

The disposition alert is `NSAlert.runModal`, which blocks deviceterm's own main
loop — an in-app driver literally cannot dismiss it, which is the whole reason
the harness runs out of process.

- **Precondition:** a tab that booted an **approved** sim.
- **Trigger:** prefer `deviceterm-uitest drive key opt+cmd+w` — it posts the key
  and returns cleanly. **⌥⌘W, not ⌘W:** ⌘W closes the *focused pane*, so with
  the sim pane focused it would detach the mirror and never raise the alert.
  ⌥⌘W is Close Tab whatever holds focus. (Pressing the pill's `✕` via
  `drive click --ax "deviceterm.tab.<shortId>.close"` also raises the alert, but
  that AXPress triggers `runModal` and blocks, so the drive returns **`ok:false`
  "pressing deviceterm.tab.<shortId>.close failed"** *even though the alert is
  up*: the message interpolates whatever needle you passed, so it is not a fixed
  string. The blocked-modal path reports `pressing <needle> failed`, but so does
  every other unsuccessful AXPress, so that wording narrows the possibilities
  without confirming anything. Confirm the alert by observing it. The other two
  press failures mean no AXPress was attempted at all and are findings in their
  own right: `no accessibility element titled <needle>` and `<needle> exists but
  is not pressable`. Address the ✕ by identifier: every pill's ✕ has the title `✕`,
  so `--ax "✕"` presses whichever one the walk reaches first, which need not be
  the tab you meant.) The alert reads: message
  **`Close this tab?`**, informative *"Detach keeps any simulators this tab
  booted running. Shut Down stops them."*
- **Observe:** the alert is a **separate `NSAlert` window** sitting above the
  main window. `capture window` captures the **frontmost** deviceterm window, so
  with the alert up it captures the *alert* (not the window behind it) — that's
  the pixel view. Cross-check with `ax dump`, where the alert is a distinct
  **empty-titled `AXWindow`** naming its three buttons:
  **`Detach (Keep Sims Running)`**, **`Shut Down Sims`**, **`Cancel`**.
- **Dismiss safely:** `deviceterm-uitest drive click --ax "Cancel"`. Re-observe;
  the alert is gone and the tab remains. **Never** press `Shut Down Sims` here.

### 6. Quit prompt ⌘Q *(needs a sim — terminates the app under test)*

- **Trigger:** `deviceterm-uitest drive key cmd+q`. Alert: message
  **`Quit DeviceTerm?`**, informative *"Simulators booted from DeviceTerm are
  still running."*, buttons **`Keep Running`** and **`Shut Down All & Quit`**.
- **Observe:** `capture window` + `ax dump` name both buttons. Note there is
  **no Cancel** on this alert.
- **Both buttons act**, so run this **last**: press
  `deviceterm-uitest drive click --ax "Keep Running"` to quit deviceterm
  *without* disturbing the user's sims. This ends the session — you'll need to
  reopen deviceterm to continue.

### 7. Mirror Physical Device picker + device roster

- **Assert roster:** `deviceterm devices list --json` — array of
  `{id, kind (sim|device), name?, model?, osVersion?, state?, attached, ownerSessionId?}`.
- **CLI attach:** `deviceterm device attach <ref>` is the unified explicit
  attach (sim UDID, physical deviceId, or name); `--json` receipt is
  `{ok, target, kind}`.
- **GUI picker:** **`Mirror Physical Device…`** (with the ellipsis glyph) is in
  the **Shell** menu, below Split Down — it creates a pane, so it sits with the
  splits rather than with the Device menu's drive-a-pane items. Open Shell, then
  `deviceterm-uitest drive click --ax "Mirror Physical Device…"`; the device
  picker window appears. `capture window` + `ax dump` should name the connected
  devices, and they should match the `devices list --json` roster.

### 8. Health cross-check (cheap sanity, no sim)

- `deviceterm doctor --json` → `{ok, checks:[{name,status,detail}], session?,
  targets?, role?, allowedMethods?}`; `ok:true`.
- `deviceterm-uitest doctor` → `ok:true` with `screenRecording:true` and
  `accessibility:true`. If either is false, you are in a false-pass state — stop.

---

## Reporting

For each scenario, report the three observations you actually made (the `--json`
number, the AX finding, the pixel finding) and whether they agreed. When they
disagree, that's the finding — quote all three; don't reconcile them by picking
the one you expected. If a documented GUI string here no longer matches what you
observe, report the drift so this playbook can be corrected.
