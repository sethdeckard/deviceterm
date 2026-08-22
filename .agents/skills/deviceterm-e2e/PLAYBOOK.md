# deviceterm E2E playbook

Neutral, tool-agnostic instructions for an agent running **inside a deviceterm
Automation Tab** that has been asked to end-to-end test **deviceterm itself** —
its own AppKit GUI (window/tab/pane chrome, status item, modal prompts, device
picker), not just the CLI/daemon contract. The Claude and Codex `SKILL.md` files
point here; this is the single source of truth.

An ordinary tab is not enough. The scenarios open, select, and move tabs and
windows, and those verbs require a live automation grant that only the GUI
issues, when a person opens an Automation Tab (Shell > Open Automation Tab,
⇧⌘T). Closing a tab or window still needs no grant. Preflight checks for the
grant, so you will find out before a scenario does.

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
four hold: the harness resident is up **and** holds both TCC grants, deviceterm
is running, deviceterm reports at least one window, and your host tab holds a
live automation grant.

The grant gate reads `deviceterm doctor --json` and looks for `tab.capture` in
`allowedMethods`. It ignores `$DEVICETERM_SESSION_ROLE`, because the role string
survives a grant that never landed or was revoked, so it would pass in a tab
that cannot actually run the scenarios.

`tab.capture` is a probe, not a verb any scenario uses. Probing one of the
workspace verbs would make the gate depend on the same scope tagging it exists
to check, so a verb tagged wrong would report a grant this tab doesn't hold.

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
  - **No automation grant** → ask them to open an Automation Tab (Shell > Open
    Automation Tab, ⇧⌘T) and rerun the skill from it. Like the TCC grants, this
    is a human action with no agent-side path: the daemon refuses a grant
    request from anything but the signature-validated GUI, so you cannot mint
    one for yourself.

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
- **Close only tabs this run opened, and never your own.** `--tab` defaults to
  `current`, which is the tab your shell is running in, so a bare
  `deviceterm tab close` ends your own session and takes the run with it. Name
  the target explicitly, every time: `--tab <shortId>`. The GUI paths are
  harder to aim, because they follow focus rather than a name: `cmd+w` closes
  the focused *pane* and escalates to closing the whole tab when that terminal
  is the tab's last, and `opt+cmd+w` is Close Tab regardless of focus. Leaving
  a tab open and reporting it beats closing the wrong one.
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

**One thing voids the ⇔: protection.** Both CLI listings are filtered to what
the *calling* session may see; AX is not filtered at all. A tab another session
protected is missing from your `tabCount` and your `tabs list`, while its pill
is still in the strip and still in the dump. Run the cross-check on a workspace
with no protected tabs, or expect AX to exceed the CLI by exactly the tabs you
cannot see.

**Count pills by identifier, never by role.** A pill is a node whose
`identifier` starts `deviceterm.tab.`, does not end `.close` (that is a pill's
✕), and is not `deviceterm.tab.new` (the strip's "+"). Counting by role instead
will overshoot: the "+" and every ✕ are `AXButton`, and so is a pile of window
chrome, so an app-wide `AXButton` count is a different number entirely. Scoping
to the window does not rescue it, because the chrome is in the window too.

**`.agents/skills/deviceterm-e2e/helpers/tab-pills.sh` applies that predicate
for you.** It prints one pill identifier per line, sorted. With no argument it
takes its own fresh dump; hand it a path to read one you already have. It exits
non-zero and says why when the dump reports `ok:false` or is `truncated`,
rather than printing an empty list that would read as a genuine "no tabs".

**Redirect it to a file and check its exit status; never pipe it.** That status
is the whole of the protection above, and a pipeline discards it:
`tab-pills.sh | wc -l` reports `wc`'s status, which is 0, and prints `0` for a
dump the helper refused — the "no tabs" reading it exists to prevent, restored
in full. (`pipefail` is off by default in both bash and zsh, so this is the
behaviour you get, not a corner case.) Count with
`tab-pills.sh >/tmp/e2e-pills.txt && wc -l </tmp/e2e-pills.txt` instead, and
two saved files also give you `comm -13 /tmp/e2e-before.txt /tmp/e2e-after.txt`
for what appeared between them, which the cleanup paths need. **A non-zero exit
means you have no pill count at all** — not a count of zero — so re-dump or
report rather than carrying the number forward.

The pill roles are worth knowing for assertions other than counting:

| element | role | identifier | notes |
|---|---|---|---|
| pill | `AXCheckBox` (subrole `AXToggle`) | `deviceterm.tab.<shortId>` | `title` is the display title; **`value` 1 = selected, 0 = not** |
| its ✕ | `AXButton` | `deviceterm.tab.<shortId>.close` | `title` is `✕`, `help` is `Close Tab` |
| the "+" | `AXButton` | `deviceterm.tab.new` | **no `title` key**; `description` and `help` both read `New Tab` |

**Read selection from `value`, not `focused`.** `focused` is `false` on every
pill including the selected one, so a `focused` predicate silently matches
nothing.

**Your own pill carries an automation badge.** Every automation-role tab's pill
shows a `wand.and.rays` marker that agent-role tabs don't have, and you run from
one. The badge publishes no `deviceterm.tab.` identifier, so counting is
unaffected, but a pixel comparison of the strip will show it.

**Don't cross-check a pill's `title` against the CLI's `displayTitle`.** They
are not the same value and are not read at the same moment, so they disagree for
three independent reasons, none of which re-reading makes go away:

- **Sampling.** A shell whose title carries a spinner or a clock changes between
  the two reads. A run has already seen `◐` in one source and `◑` in the other
  on the same tab. Re-reading *identifies* this one, because the difference moves
  from read to read instead of staying put, but it will not converge while the
  title goes on animating.
- **Normalization.** The pill renders the title as the GUI has it, while
  `displayTitle` is the form that crosses the wire: NFC-composed, stripped of
  controls and most default-ignorable scalars, and truncated on grapheme
  boundaries to a 256-byte budget. (Joiners and variation selectors are kept
  on purpose, being orthographic in several scripts and structural inside emoji
  sequences, so "stripped of the invisible" is not quite the rule.) A long or
  oddly-composed title therefore differs **permanently**, and no amount of
  re-reading converges it.
- **Elision.** `displayTitle` is deliberately **absent** whenever the label would
  tell you nothing `name` does not already: the title *is* the name, or it is the
  GUI's generic fallback for a tab with no name, no title and no known directory.
  It is also absent on the non-primary terminals of a split tab, whose title
  publishes under the primary's session. A pill with a perfectly good title
  beside a row with no `displayTitle` at all is the designed behaviour, not a
  dropped update.

Compare identifiers and counts, which are stable and are what the cross-check
actually needs. A title difference is a finding only once you can rule out all
three of the above, which in practice usually means it is not one.

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
  **Router-selected** window (`workspace.selectedWindowID`), which moves only when
  a route acts on a *window* (opening, closing, or focusing one), not on plain
  focus changes — so after you click a different window, `isKey` still points at
  the old one. Tab-level routes leave it alone entirely: selecting a tab does not
  make its window key.

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
first read can be nothing but this, so re-read before you report one. On a quiet
machine everything here may well settle inside a couple of hundred milliseconds
and you will never see a retry; that is not evidence the bound is unnecessary,
only that nothing was in flight.

**Record a baseline before you mutate.** The counting and state-transition
assertions in the scenario library are *deltas*: "its length grew by 1",
"re-assert the count dropped", "count deltas, not absolutes". None of those is
checkable without the "before", and nothing else in this document will remind you
to capture it. Plenty of other assertions are absolute and need no baseline: a
receipt's shape, an alert's wording, the status-item badge, `doctor`'s `ok`.

Take the same three vantage points you intend to assert on, so a surprise in the
baseline itself (tabs left over from an earlier run, a window you did not expect)
surfaces before it is tangled up in a delta.

---

## Scenario library

Each scenario: **goal → mutate → assert (`--json`) → observe (harness) →
verify**. The exact CLI verbs, JSON keys, and GUI strings below are current as
of this writing; if a string here doesn't match what you observe, treat the
mismatch itself as a finding rather than papering over it.

### 1. Tab lifecycle — open / rename / select / close

**Run the steps in the order they appear below**, which is the order of this
heading. Rename before select is deliberate: the rename step demonstrates that
the titlebar tracks the *selected* tab rather than the renamed one, and that
only shows up while the tab `tab open` just created is still selected. Reorder
it and the check passes vacuously.

The four mutation verbs here all accept `--json`, which is worth using: the
human line is a loose echo, while the receipt is a fixed shape you can assert
on.

| verb | `--json` receipt |
|---|---|
| `tab open` | `{ok:true, window}` (echo of the requested window ref, `"current"` when omitted) |
| `tab rename` | `{ok:true, tab, name?}` (`name` omitted when restoring the automatic title) |
| `tab select` | `{ok:true, tab}` |
| `tab close` | `{ok:true, tab, mode}` |

None of them returns the new tab's id: the GUI mints it asynchronously, so
`tab open` is fire-and-forget and you learn the new `shortId` from `tabs list`,
not from the receipt.

- **Baseline:** before mutating anything, record all three vantage points:
  `deviceterm tabs list --json`, `deviceterm windows list --all --json`, and an
  `ax dump`. The counts and the selection below are measured against this; the
  rest (receipt shapes, the renamed title) stands on its own.

  **Keep two `shortId`s straight from here on.** `<caller>` is your own tab: take
  it from `deviceterm tab info --json`, whose `shortId` is the tab's **primary**
  terminal. Do **not** take it from the `tabs list` row with `current: true`.
  That list has one row per terminal *session*, so if you are sitting in the
  secondary pane of a split tab, that row's `shortId` names your session rather
  than your tab, and it will match no pill and no `selectedTabShortId`, because
  both of those speak only the primary's. `<opened>` is the tab the next step
  creates, read from the `tabs list` row that appears; a fresh tab has exactly
  one terminal, so its row is its primary either way.

  The steps below name one or the other deliberately, because `tab open` leaves
  `<opened>` selected: pointing the select step at `<opened>` would "select" a
  tab that is already selected and pass without moving anything.
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
  the CLI or not. With no protected tabs a split tab is therefore several
  session rows, one `tabCount`, and one pill, with all three correct. Use
  `tabCount` and the pills when you mean tabs.
- **Observe:** `.agents/skills/deviceterm-e2e/helpers/tab-pills.sh
  >/tmp/e2e-pills.txt && wc -l </tmp/e2e-pills.txt` counts the pills, taking its
  own dump. **Redirect, don't pipe** — see the flagship cross-check: piping to
  `wc -l` prints `0` and exits 0 for a dump the helper refused. Run
  `deviceterm-uitest ax dump` directly when you want the rest of the tree as
  well. Then `deviceterm-uitest capture window --out /tmp/e2e-tabs.png` and read
  the PNG.
- **Verify:** the flagship cross-check holds (count matches across JSON + AX +
  pixels).
- **Rename:** `deviceterm tab rename "My Tab"` sets the GUI **manual title**
  (top of the precedence chain: manual → OSC → session name → cwd basename →
  `shell`). **Do not assert it via `tabs list --json`'s `name`**: that field is
  the daemon *session name* layer (set at `session.create` / worktree
  auto-name), which a manual rename does not touch, so it reads the same before
  and after however the rename went. Expect it to be **absent rather than
  unchanged** much of the time: the key is optional and the row omits it when
  the session was never named, so a tab you rename may have no `name` at all.
  That absence is the normal case, not a finding.

  The resolved title does reach the daemon, as **`displayTitle`** on the same
  row, so it is a second opinion rather than nothing. It is not a substitute for
  AX and pixels here, because the GUI pushes it asynchronously: a read
  immediately after the rename can still show the old title. It can also be nil,
  for instance on the non-primary terminals of a split tab, whose title
  publishes under the primary's session.

  Verify through the harness instead, on **`<caller>`'s pill**, whose `title`
  reads `My Tab`. A bare `tab rename` renames `<caller>`, because `--tab`
  defaults to `current`, which is the tab your shell is in.

  **The titlebar will not agree yet, and that is the point of running this
  before the select step.** The titlebar shows the **selected** tab's title, and
  `<opened>` is still selected, so it goes on reading `<opened>`'s title while
  the rename has worked perfectly. Assert the pill now; the titlebar becomes
  assertable one step later, once select moves to `<caller>`. If you would
  rather rename the selected tab outright, name it: `tab rename --tab <opened>
  "My Tab"`.
- **Select:** `deviceterm tab select --tab <caller>`. **Target `<caller>`, not
  `<opened>`**: `<opened>` has been selected since it was created, so selecting
  it again moves nothing and every assertion below passes on pre-existing state.
  `<caller>` is the one tab you know is *not* selected right now.

  **Do not assert with `tabs list --json`'s `current`** — that flag marks the row
  matching the *calling shell's* `DEVICETERM_SESSION`, i.e. the agent's own tab,
  regardless of which tab is selected. (It will read `true` on `<caller>` both
  before and after this step, which is exactly why it proves nothing.) Assert on
  **`selectedTabShortId`** instead, taken from the `windows list --all --json`
  row for **the window under test**: it should change from `<opened>` to
  `<caller>`.

  Read it from that row, not from whichever row carries `isKey:true`.
  `tab select` selects a tab *within* its window and does not change which
  window is key, so on a multi-window workspace `isKey` can be pointing
  somewhere else entirely and its `selectedTabShortId` will not move. With the
  single window this playbook asks for there is one row, and the distinction
  cannot bite.

  Confirm it in AX too: `<caller>`'s pill **`value` is 1** and every other
  pill's is 0. Do not reach for `focused`, which is false on all of them.

  This is also what makes the rename step assertable: with `<caller>` selected,
  the titlebar should now read `My Tab`, the title it declined to show while
  `<opened>` held the selection.

  **GUI-only select:** `drive click --ax "deviceterm.tab.<opened>"` selects that
  exact tab, moving selection back the other way. Prefer the identifier over the
  title, which is the live display title and collides freely (several tabs in one
  window commonly share one).
- **GUI-only open:** `deviceterm-uitest drive key cmd+t` (New Tab), or
  `drive click --ax "deviceterm.tab.new"` to press the strip's "+" specifically.
  Both open a tab; re-assert the count grew. **Note each new tab's `shortId`**
  from the `tabs list` row that appears, as `<gui>`; running both variants makes
  two of them, and the close step below has to account for every one.

  Do **not** use `drive click --ax "New Tab"` for this. That string matches the
  **Shell** menu item by title and the "+" by description, and the element search
  walks the whole application, so it presses one of them without telling you
  which. The identifier is unambiguous, and the "+" publishes no title at all, so
  the identifier is the only way to name it.
- **Close:** `deviceterm tab close --tab <opened> --mode detach`. Re-assert the
  count dropped.

  **Then close every other tab this scenario opened**, one `tab close --tab
  <gui> --mode detach` per identifier you noted at the GUI-only open step. The
  count should return to its baseline; if it does not, say which tabs you left
  and why. Running every step opens three tabs, one by CLI and one per GUI
  variant, and closing only the first is how an operator's window fills with
  strangers.

  **No modal appears here, even if the tab booted a sim.** `--mode` already
  states the disposition, so there is nothing to prompt for; the CLI hands it
  straight to the close route. The disposition alert belongs to the GUI close
  paths, which carry no mode and therefore have to ask (scenario 5).

  **Never close `<caller>`**, and name every target explicitly, per the safety
  rule above. `--tab` defaults to `current`, which is `<caller>`, so omitting the
  flag here closes the tab you are working in and ends the run.

  `--mode` takes **`detach`** or **`shutdown`**. Always pass `detach`: it leaves
  any sims the tab booted running, while `shutdown` stops them, which is the
  thing you may never do to the user's sims without approval. An unrecognized
  value falls back to `detach`, so a typo fails safe, but do not rely on that
  in place of typing it.
- **Clean up, on every exit path including an early one.** Two things need
  putting back, and the standing rule to stop the moment you find a bug would
  otherwise skip both, leaving damage you caused as a second finding on top of
  the one you went to report:

  - **The title.** `deviceterm tab rename --tab <caller>` with no name puts
    `<caller>` back on automatic titling. The rename step set a manual title on
    **your own** tab, and closing anything does not undo it.
  - **The tabs.** Close every tab this scenario opened that is still open:
    `<opened>`, and each `<gui>`. On the success path the Close step has already
    taken them; on an early exit it has not, so walk the list yourself. Compare
    the tab count against the baseline as the check.

  This is owed from the first step that opened or renamed anything, not just at
  the end: if you stop early, clean up first, then report. Say so if a cleanup
  step itself fails. Putting back what this scenario deliberately moved is not
  "fixing a bug" and is not what the observe-only rule forbids.

### 2. Pane split + rearrange

- **Setup:** record **the set of pill identifiers** already in the strip as
  `<before>`, before anything else:
  `.agents/skills/deviceterm-e2e/helpers/tab-pills.sh >/tmp/e2e-before.txt`.
  **If that exits non-zero, stop before mutating anything**: an empty or partial
  `<before>` is worse than none, because the cleanup at the end would read the
  operator's own tabs as tabs this scenario opened. Not just the count: that
  cleanup needs to know which tabs were already theirs, and only a set can tell
  it that. Then
  `deviceterm tab open`, and note the new tab's `shortId` as
  `<work>`. Everything below runs against `<work>`, never your own tab: the
  GUI-only steps close panes by focus and can escalate to closing the whole tab,
  so a split made in your own tab puts the run one keystroke from ending itself.
  Select `<work>` (`deviceterm tab select --tab <work>`) so the GUI steps, which
  follow selection and focus, act on it.
- **Mutate:** `deviceterm pane open --terminal --tab <work>` splits that tab.
  **Pass `--tab` explicitly.** Omitting it splits the *calling shell's* tab
  regardless of what is selected in the GUI, because `--tab` defaults to
  `current`, and that is the one tab this scenario must leave alone.
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

  Both keys aim by **focus**, not by name, so neither can be pointed at a tab
  and both take whatever is selected. Confirm `<work>` is still selected before
  pressing either, per the closing rule in **Safety rules**; if selection has
  moved back to your own tab at any point, these close *that* instead.

  **Re-read `<work>` from a fresh dump between closes.** A tab's pill identifier
  is its *primary* terminal's, and the primary is just the first terminal the tab
  holds, so closing the primary pane promotes the survivor and the identifier
  changes underneath you. A `<work>` captured at Setup will then match nothing in
  the strip, and "the tab is gone" is the wrong conclusion to draw from that. This
  is the join-key caveat from the flagship cross-check biting in practice.
- **Clean up, on every exit path including an early one:** `<work>` usually
  outlives this scenario. ⌘W closes a *pane*, so on a split tab it removes one
  and leaves the tab standing, while ⌥⌘W does close the tab outright, so whether
  `<work>` is still open depends on which keys you ran. Close it explicitly with
  `deviceterm tab close --tab <work> --mode detach` if it is, which is what the
  identification below is for.

  **Identify it by what is new, not by what is selected.** `opt+cmd+w` may
  already have taken the whole tab, and a ⌘W that closed the primary pane will
  have promoted the survivor, so the Setup identifier can name a terminal that no
  longer exists. Take the set again and let `<new>` be the difference:
  `.agents/skills/deviceterm-e2e/helpers/tab-pills.sh >/tmp/e2e-after.txt` then
  `comm -13 /tmp/e2e-before.txt /tmp/e2e-after.txt`, which needs both sides
  sorted and the helper sorts what it prints. **If that run exits non-zero you
  have no set to diff** — close nothing, and report the tabs you opened by name
  so the operator can. Otherwise:

  - `<new>` is **empty** → nothing this scenario created is still open. **Close
    nothing.**
  - `<new>` is **exactly one identifier** → that is `<work>`, whether or not it
    still answers to the Setup value. **Strip the `deviceterm.tab.` prefix
    before closing it**: `--tab` wants the bare `shortId`. Handing it the whole
    identifier does not fail loudly, because a value containing dots is not
    short-id-shaped, so the parser classifies it as a tab *name* and resolves it
    against tab names instead: not-found at best, and the wrong tab if one
    happens to carry that name.
  - `<new>` has **more than one** → something you did not expect happened. Close
    nothing and report the set.

  This is the only recovery here that is safe to write down. Every tab the
  operator already had is in `<before>` by construction, so it can never be a
  candidate no matter what else moves. Do **not** substitute "the selected tab":
  closing a tab makes DeviceTerm select a *neighbour*, which is the operator's,
  and the AX pill and `selectedTabShortId` will then agree with each other about
  it perfectly. Nor is a tab count enough, because the close is asynchronous: a
  count read a moment too early still shows the tab present, and by the AX read
  it is gone and a neighbour is selected.

  **Do not go looking for it in `tabs list`** either. Those rows are terminal
  sessions with no tab grouping of any kind, so after a promotion nothing in a
  surviving row tells you which tab it belongs to.

  If you stop early, do all of this before you report, and say so if a close
  fails.
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
