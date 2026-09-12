# deviceterm E2E playbook

Neutral, tool-agnostic instructions for an agent running **inside a deviceterm
Automation Tab** that has been asked to end-to-end test **deviceterm itself** —
its own AppKit GUI (window/tab/pane chrome, status item, modal prompts, device
picker), not just the CLI/daemon contract. The Claude and Codex `SKILL.md` files
point here; this is the single source of truth.

**Driving the device inside a pane is a different skill.** Touch, hardware
input, rotation, and `ax tree`/`point`/`sweep` against a simulator or connected
device belong to `.agents/skills/deviceterm-device-e2e/PLAYBOOK.md`. Its
instrument is the shipped CLI, so it needs none of the preflight below: no
harness, no TCC grants, no automation grant. Gating a sim run behind this
skill's gate would refuse a machine that can run all of it.

An ordinary tab is not enough. The scenarios open, select, and move tabs and
windows, and those verbs require a live automation grant that only the GUI
issues, when a person opens an Automation Tab (Shell > Open Automation Tab,
⇧⌘T). Preflight checks for the grant, so you will find out before a scenario
does.

The grant also decides how far the *other* verbs reach. Without one, a tab
closes, renames, and opens panes only in itself, and `tab close` even there
only while it holds the tab's single terminal. That is why a scenario that
closes or renames the tab it just opened needs the same grant as one that
selects it: the target is another session's tab either way.

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
- **AX assertions — `.agents/skills/deviceterm-e2e/helpers/ax-dump.sh`.** Use
  this instead of a raw `uitest.sh ax dump` in every assertion and poll. It
  retries once after a transport failure or a retryable tree-validation
  failure, then emits only a complete `ok:true` tree. For `com.deviceterm`, a
  usable dump must also contain at least one non-cycle, non-skipped `AXWindow`.
  An application root containing only a menu bar or a cycle-marked application
  node is a transient structural failure, not proof that DeviceTerm has no
  windows. A serviced `ok:false` refusal is final. Call
  `uitest.sh ax dump` directly only when diagnosing the harness itself.

This split is intentional: the harness holds Screen Recording + Accessibility,
capabilities kept out of the shipped product, so it lives only in the dev
checkout. The skill therefore only works from a tab in the deviceterm repo with
the harness built and its resident up (`make uitest-run`).

Write screenshots to a scratch path you control (your session scratch dir, or
`/tmp`), then read the PNG back to inspect it. Example paths below use
`/tmp/e2e-*.png`; substitute your own.

The harness client speaks to a resident harness process over a private socket.
A reply is JSON on stdout; a non-zero exit means failure, and not every failure
produces a reply (see below). Reply shapes:

| verb | on success |
|---|---|
| `ping` | `{ok:true, resident:true, pid, tool}` |
| `doctor` | `{ok, resident, pid, bundleId, bundlePath, screenRecording, accessibility}` |
| `capture window --out <p> [--bundle-id <id>]` | `{ok:true, path, width, height, scale, bundleId}` |
| `capture status-item --out <p>` | present: `{ok:true, present:true, path, width, height, scale}`; hidden: `{ok:true, present:false}` |
| `ax dump [--bundle-id <id>]` | `{ok:true, bundleId, truncated, unreadable, tree}` |
| `drive key <shortcut>` | `{ok:true, shortcut, bundleId, pid}` |
| `drive click <x> <y>` | `{ok:true, bundleId, x, y, screenX, screenY}` |
| `drive click --ax <label>` | `{ok:true, ax, bundleId}` |

**`--bundle-id` reaches deviceterm and its daemon, and nothing else.** Any other
target is refused before the harness uses either grant, so it is not a way to
read, screenshot, or drive another app. The daemon is the one you will name in
practice, for the status-item badge in scenario 4.

**The two tools report failure differently, and neither is stdout-only, so
read both streams and lead with the exit status.**

The harness answers a *serviced* refusal with `{"ok":false,"error":…}` on
**stdout**, which is why the helpers redirect rather than pipe: a refusal that
lands in a file can still be quoted. But a request that never reached the
resident has no reply to render, and those paths write a human line to
**stderr** and produce no JSON at all. `helpers/uitest.sh` exits **3** with a
build hint when the harness is not there, and `doctor` prints a multi-line
grant-remediation block to stderr on top of its report. Decoding stdout without
checking the status will hand you an empty string on exactly the failures you
most need the reason for.

The raw client distinguishes a resident that closed before a full frame from
one that missed its reply deadline. `ax dump` gets a longer deadline than the
other methods because one tree walk makes many cross-process reads. The
`ax-dump.sh` wrapper retries either transient once; it never retries `drive`,
whose first request may have landed even when its receipt did not.

The `deviceterm` CLI emits a typed envelope on stdout instead:

```json
{"error": {"code": "intent.automationRequired", "message": "…"}}
```

Assert on `code`; the wording is not stable. **Whether you get one depends on
the output mode, which is decided from argv before anything is parsed.** The
mode is JSON when argv carries `--json`, and also for any `ax` command, whose
verb alone selects it. So `ax` verbs produce an envelope without the flag, and
a *malformed* invocation still produces one whenever the mode says JSON,
parse failure and all. Only outside both cases is a failure just the human line
on stderr with nothing on stdout.

Exit status is 1 for everything here except `wait.timeout`, which exits 124 —
and note that is the code, not the verb: a `deviceterm wait` can fail for other
reasons and exit 1 like anything else.

`<shortcut>` is like `cmd+t`, `cmd+shift+right`, `cmd+w`. `drive click <x> <y>`
takes **window-normalized** coordinates in `0..1` (0,0 = window top-left).
`--ax <label>` presses the first accessibility element whose **title,
description, or identifier equals `<label>` exactly** — copy the labels in this
playbook verbatim; a near-miss finds nothing.

**deviceterm must be frontmost for a main-menu press, and `ok:true` is not proof
one landed.** `drive click --ax` against a **main-menu item** returns
`{"ok":true}` and does nothing at all when deviceterm is in the background.
Measured both ways with the same command and nothing else varied: frontmost
raised the sheet, backgrounded raised nothing and still reported success. The
harness activates its target before driving, but that activation is too transient
to carry a main-menu press. So assert a post-condition rather than reading the
receipt — an `AXSheet` or alert present in a fresh `ax dump`, a changed count, a
changed title. A silent no-op looks exactly like a clean pass, and a false pass
is worse than a failure.

**Never force that foreground state by bundle id.** Both
`osascript -e 'tell application id "com.deviceterm" to activate'` and
`open -b com.deviceterm` resolve through LaunchServices, which cannot tell this
checkout from an installed `/Applications/DeviceTerm.app`. Launching the
installed copy beside a debug build collides on the one bundle id, launchd label,
and mach service, and wedges the daemon handshake badly enough to need a force
quit. If deviceterm is not frontmost, bring it forward the way a user would and
re-run the step.

This was measured for `drive click --ax` against main-menu items. **Whether
`drive key` carries the same exposure is untested** — treat it as an open
question, not a guarantee either way. Note also that `drive key` is not a
universal fallback: `Rename Tab…`, for one, publishes no key equivalent at all.

**The harness only ever captures deviceterm's own windows, never a whole
display.** `capture window` grabs the frontmost deviceterm content window —
which, when an app-modal alert is up, is the alert itself, at natural size. A
window-modal **sheet** frames differently: you get the whole window scaled
down with the sheet composited over it, so the image's dimensions track the
sheet while its content is the window behind it. The close prompts are sheets
(scenario 5); the quit prompt is an app-modal alert (scenario 6).
`capture status-item`
grabs just the daemon's menu-bar badge (or reports it absent). There is
no full-screen capture, so nothing on screen outside deviceterm is ever
photographed, and multi-monitor setups are a non-issue.

## Preflight (always first)

Run `.agents/skills/deviceterm-e2e/helpers/preflight.sh` to **check** the
environment — the agent verifies, it does not provision. It passes only when all
four hold: the harness resident is up **and** holds both TCC grants, deviceterm
is running, deviceterm reports at least one window, and your host tab holds a
live automation grant.

The grant gate reads `deviceterm doctor --json` and looks for the RPC method
`pane.captureText` in `allowedMethods`. It ignores
`$DEVICETERM_SESSION_ROLE`, because the role string
survives a grant that never landed or was revoked, so it would pass in a tab
that cannot actually run the scenarios.

`pane.captureText` is a wire-method probe, not a CLI verb any scenario uses.
Probing one of the workspace verbs would make the gate depend on the same scope
tagging it exists to check, so a verb tagged wrong would report a grant this
tab doesn't hold.

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
- **Close only tabs this run opened, and never your own.** An omitted tab ref
  defaults to the tab your shell is running in, so a bare
  `deviceterm tab close` ends your own session and takes the run with it. Name
  the target explicitly, every time: `deviceterm tab close <id>`. The GUI paths are
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
  `capture window` — it is the daemon's `NSStatusItem`, not part of any
  deviceterm app window. (Its *window* belongs to Control Center, which hosts
  every menu-bar extra; the harness finds it through accessibility.)
- Use `.agents/skills/deviceterm-e2e/helpers/ax-dump.sh` for AX assertions. A
  raw `ax dump` can miss its reply deadline. The helper retries once and fails
  rather than turning that into an empty UI.
- **A nested `AXApplication` terminates the walk rather than being followed.**
  Some targets vend their own application element as a child of itself. An
  ancestor the walk recognizes by element identity is marked `cycle`; any other
  nested application is marked `skipped`. Neither is descended into, which
  keeps the depth ceiling and node budget available for the sibling windows you
  came for. `ax-dump.sh` accepts a marked nested application and rejects an
  unmarked one, because an unmarked one means neither guard stopped it.
- A node marked `"skipped": true` was deliberately not descended into, and it
  carries no `children` key. This is **not** `truncated`, which means a limit
  ran out: re-dumping or raising a ceiling will never reveal a skipped subtree,
  so don't treat it as a flake. Two rules produce it: the Apple menu (below),
  and an `AXApplication` below the root.
- A node marked `"cycle": true` *is* one of its own ancestors, established by
  comparing element identity rather than role. The walk stops there because
  everything below it is already in the tree above it. Like `skipped` and
  unlike `truncated`, re-dumping reveals nothing new. The two markers are kept
  apart on purpose: `cycle` asserts the element was met before, which only an
  identity comparison shows, while `skipped` only says a rule declined.
- A further marker, `"unreadable": ["AXChildren", "AXTitle"]`, lists the reads
  that failed on that node: `AXChildren`, any of the attributes above, or the
  `AXPosition`/`AXSize` pair behind its frame. It is a **list of AX attribute
  names**, not a boolean, and it names the accessibility attribute rather than
  the JSON key the dump uses for it. Unlike the other two markers this one *is*
  worth retrying, because what failed is unknown rather than absent. It exists
  because a failed read would otherwise serialize exactly like an element that
  has nothing: a childless node, or one carrying no `identifier`, which is how
  a timed-out walk comes to read as an empty UI or a short pill list.
- **The top-level `unreadable` flag is narrower than the per-node marker.** It
  is true only when some node failed an `AXChildren` or `AXRole` read. Those
  structural reads can hide a node or its place in the tree, so they decide
  whether the dump is usable as a whole.

  An `AXIdentifier` failure stays on the affected node's `"unreadable"` list.
  Mounted Simulator panes routinely contain system-vended controls whose
  identifiers cannot be read. Rejecting the whole tree for one such control
  removes every accessibility vantage point while the pane is mounted.

  Check the per-node marker on every node your assertion touches. If an
  assertion depends on an identifier and that node reports
  `"AXIdentifier"` as unreadable, treat the assertion as inconclusive and
  re-dump. The same rule applies to `AXTitle`, `AXValue`, frame, and
  `AXFocused`. `ax-dump.sh` and `tab-pills.sh` refuse a structurally unreadable
  dump for you, so you only meet the top-level flag using the raw client.
  The dump walks from the application element, so
  the menu bar comes along; the leading menu bar item is the Apple menu, which
  macOS owns and fills, and it is skipped because a dump of the target app's UI
  has no business carrying another program's. Every other menu, deviceterm's own
  included, follows the normal traversal policy, which means it can still be cut
  short by a depth or node ceiling and marked `truncated`. Don't paste a
  system-owned subtree into a report if you find one by another route.

## The flagship cross-check

The single most trustworthy assertion the harness exists for:

> `window list --all --json` reports `tabCount = N` for the window under test
> **⇔** the AX dump contains exactly `N` tab pills, **and** a screenshot shows
> `N` pills in the strip.

If the number, the AX tree, and the pixels disagree, that is a real bug — report
it with all three observations.

**One thing voids the ⇔: protection.** Both CLI listings are filtered to what
the *calling* session may see; AX is not filtered at all. A tab another session
protected is missing from your `tabCount` and your `tab list`, while its pill
is still in the strip and still in the dump. Run the cross-check on a workspace
with no protected tabs, or expect AX to exceed the CLI by exactly the tabs you
cannot see.

**Refusals differ behind that, if you go on to touch such a tab.** A tab you
cannot resolve at all fails in resolution as `intent.notFound`, which
deliberately does not distinguish a protected foreign tab from one that isn't
there.

A tab you *can* resolve but own no terminal in refuses with
`intent.automationRequired`; a live automation grant is precisely what
satisfies that authority check, including for `tab protect` and
`tab unprotect`. Protecting your own tab never locks you out of it, so you can
always unprotect from inside.

**Count pills by identifier, never by role.** A pill is a node whose
`identifier` starts `deviceterm.tab.`, does not end `.close` (that is a pill's
✕), and is not `deviceterm.tab.new` (the strip's "+"). Counting by role instead
will overshoot: the "+" and every ✕ are `AXButton`, and so is a pile of window
chrome, so an app-wide `AXButton` count is a different number entirely. Scoping
to the window does not rescue it, because the chrome is in the window too.

**`.agents/skills/deviceterm-e2e/helpers/tab-pills.sh` applies that predicate
for you.** It prints one pill identifier per line, sorted. With no argument it
takes its own fresh dump; hand it a path to read one you already have. It exits
non-zero and says why when the dump is refused, truncated, structurally
unreadable, or contains no usable `AXWindow`. It never turns one of those states
into an empty successful pill list.

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

**A missing `value` is not an unselected pill.** `AXValue` is not one of the
reads behind the top-level `unreadable` flag, so a pill whose `value` failed
arrives in an accepted tree carrying no `value` key, exactly like one reading
0. Check that pill's own `"unreadable"` list before concluding it is
unselected, and re-dump if `AXValue` is in it.

**Pills carry markers, and your own has one.** An automation-role tab's pill
shows a `wand.and.rays` marker that agent-role tabs don't have, and you run from
one. A tab that is protected right now shows `lock.fill`. Both appear together
on a protected automation tab, wand first, between the pill's ✕ and its title.
Neither publishes a `deviceterm.tab.` identifier, so counting is unaffected, but
a pixel comparison of the strip will show them.

**Don't cross-check a pill's `title` against a separately sampled CLI
`tab.title`.** A shell title can change between the two reads, and the wire form
is normalized and bounded. Use an explicit `tab rename` receipt when testing a
stable title, then confirm the rendered pill and titlebar after they redraw.

**The pill identifier joins directly to the public tab `shortId`.** Both derive
from the cohort UUID and remain stable across terminal splits and
primary-terminal promotion. Carry the full tab `id` for cleanup, where an exact
durable handle is preferable.

**Always pass `--all` to `window list`.** Without it the listing is scoped to
*your* session and shows only your own tab's window, while the harness captures
and drives the frontmost window — possibly a different one entirely.

**Test with a single deviceterm window** so all three vantage points refer to the
same window and the cross-check is unambiguous. This matters because the three
observers don't agree on "which window" the way you'd expect:

- The **harness** (capture, AX dump, drive) always acts on the **AppKit frontmost
  window** — what the user is looking at.
- `window list --all`'s **`focused:true`** reads `workspace.selectedWindowID`,
  deviceterm's own record of the selected window, not a live window-server query.
  AppKit key changes sync into it, but a notification behind, and structural
  mutations (opening or closing a window, moving a tab across windows) set it
  outright. Either way a row sampled just after a change can disagree with the
  window the harness drives. Tab-level routes never move it: selecting a tab does
  not make its window key.

With one window the distinction vanishes. If you must run multi-window, don't
trust `focused` alone to name the captured window — reconcile by identity
instead (match `selectedTabId` and tab titles against the `window list` rows),
or fall back to the **workspace total** (sum `tabCount`
across all rows), which moves by the same delta no matter which window a gesture
lands in — the tactic the automated `make test-uitest` smoke uses.

## Receipts commit before the CLI returns

Workspace mutation receipts carry the committed objects, so the next command
can immediately address their `id` or `shortId`. In particular, `tab open`
awaits the terminal session mint and returns the window, new tab, and initial
terminal pane; `pane split` returns the host tab and new terminal pane. It waits
for the session ID, not for shell or surface readiness.

The AppKit accessibility tree and pixels can still lag committed model state by
a draw cycle. Poll only the observer whose presentation you are asserting, with
a bound; do not poll a list merely to discover an object already named in the
receipt.

**An app-modal alert stops the GUI-backed verbs you would poll.** While one
is up, GUI-backed verbs such as `window list --all --json` and
`tab list --all --json` time out. Poll a fresh `ax dump` instead, and see
scenario 5 for which prompts are app-modal and which are sheets that keep
answering.

**One of those alerts is not a prompt you triggered.** Attaching a pane while
Device Hub or Simulator.app is running raises a coexistence advisory, so any
sim-attaching scenario here can stall behind a modal nobody in the scenario
asked for, with the GUI-backed verbs starved exactly as above. At most one
appears per launch, and Device Hub's outranks Simulator.app's when both apply.

It is easiest to take out of the picture before the run rather than handle
mid-scenario: dismiss it once with "Don't show again", or set
`device-hub-advisory = suppress` and `simulator-app-advisory = suppress`. Set
**both** if both of Apple's apps are around, because the keys are independent
and Simulator.app's advisory is outranked rather than disabled, so suppressing
Device Hub's is what makes the other one eligible.

**Poll for the expected rendered delta rather than capturing once**, using a
fresh `ax dump` or capture. Bound the wait and report a timeout as a timeout.
The workspace receipt is already the committed JSON assertion; the bounded
retry is for presentation only.

A mismatch that survives polling is a finding worth reporting. A mismatch on the
first read can be nothing but this, so re-read before you report one. On a quiet
machine everything here may well settle inside a couple of hundred milliseconds
and you will never see a retry; that is not evidence the bound is unnecessary,
only that nothing was in flight.

**`deviceterm wait` does not replace any of this.** It exists, and the device
playbook uses it throughout, but every one of its conditions is scoped to a
*device pane*: a pane's lifecycle state, that pane's accessibility tree, its
confirmed orientation, its rendered surface. **None of the sources this section
names is one of those.** Tab counts, window state, titles, and deviceterm's own
AppKit tree have no wait verb, so the bounded poll above is still the instrument
here.

Scenario 3 is the one place a `wait` appears, and even there it is a
*precondition* rather than the assertion: it settles the daemon's view of the
pane, and the placeholder it goes on to check is the GUI's. Daemon-side
readiness does not imply the window has caught up, so the pixel and AX
assertions still poll on their own.

**Record a baseline before you mutate.** The counting and state-transition
assertions in the scenario library are *deltas*: "its length grew by 1",
"re-assert the count dropped", "count deltas, not absolutes". None of those is
checkable without the "before", and nothing else in this document will remind you
to capture it. Plenty of other assertions are absolute and need no baseline: a
receipt's shape, an alert's wording, and `doctor`'s `ok`.

Take the same three vantage points you intend to assert on, so a surprise in the
baseline itself (tabs left over from an earlier run, a window you did not expect)
surfaces before it is tangled up in a delta.

---

## Scenario library

Each scenario: **goal → mutate → assert (`--json`) → observe (harness) →
verify**. The exact CLI verbs, JSON keys, and GUI strings below are current as
of this writing; if a string here doesn't match what you observe, treat the
mismatch itself as a finding rather than papering over it.

### 1. Tab lifecycle — open / rename / focus / close

**Run the steps in the order they appear below**, which is the order of this
heading. Rename before focus is deliberate: the rename step demonstrates that
the titlebar tracks the *selected* tab rather than the renamed one, and that
only shows up while the tab `tab open` just created is still selected. Reorder
it and the check passes vacuously.

The four mutation verbs here all accept `--json`, which is worth using: the
human line is a loose echo, while the receipt is a fixed shape you can assert
on.

| verb | required committed fields in its `--json` receipt |
|---|---|
| `tab open` | `{ok:true, window, tab, pane}` |
| `tab rename` | `{ok:true, tab}` |
| `tab focus` | `{ok:true, window, tab}` |
| `tab close` | `{ok:true, closed:{resource:"tab",tab}, mode}` |

- **Baseline:** before mutating anything, record all three vantage points:
  `deviceterm tab list --all --json`,
  `deviceterm window list --all --json`, and an `ax dump`. Take the caller's
  stable public tab ID from `deviceterm tab show --json | jq -r '.tab.id'`.
  A tab list row is one GUI tab, not one terminal session; its `id` and
  `shortId` come from the cohort UUID and survive primary-terminal promotion.
- **Mutate:** capture the receipt rather than diffing a roster:

  ```sh
  opened=$(deviceterm tab open --json) || exit 1
  opened_id=$(printf '%s\n' "$opened" | jq -er '.tab.id') || exit 1
  opened_pane=$(printf '%s\n' "$opened" | jq -er '.pane.id') || exit 1
  opened_ax=$(printf '%s\n' "$opened" | jq -er '.tab.shortId') || exit 1
  ```

  The pane ID is the new terminal's session ID. The receipt is not shell
  readiness; if a follow-up terminal I/O request reports `notAttached`, wait for
  terminal readiness rather than polling for another pane ID.
- **Assert:** the receipt's tab and pane share a workspace (`.pane.tabId ==
  .tab.id`), `tab list --all` grew by one row, and the matching window's
  `tabCount` grew by one. With no protected tabs, that count also equals the AX
  pill count and the visible pill count.
- **Observe:** `.agents/skills/deviceterm-e2e/helpers/tab-pills.sh
  >/tmp/e2e-pills.txt && wc -l </tmp/e2e-pills.txt` counts the pills, taking its
  own dump. **Redirect, don't pipe** — see the flagship cross-check: piping to
  `wc -l` prints `0` and exits 0 for a dump the helper refused. Run
  `.agents/skills/deviceterm-e2e/helpers/ax-dump.sh >/tmp/e2e-ax.json` when you
  want the rest of the tree as well. Then `deviceterm-uitest capture window
  --out /tmp/e2e-tabs.png` and read the PNG.
- **Verify:** the flagship cross-check holds (count matches across JSON + AX +
  pixels).
- **Rename:** `deviceterm tab rename "$caller_id" "My Tab" --json` sets the
  caller tab's manual title. Assert `.tab.id == $caller_id`, `.tab.name ==
  "My Tab"`, and `.tab.title == "My Tab"` in the receipt, then verify the
  caller's pill reads `My Tab`. The grammar takes at most two positionals:
  quote a multi-word name, and pass both the target and name when renaming a tab
  other than current.

  **The titlebar will not agree yet, and that is the point of running this
  before the focus step.** The titlebar shows the **selected** tab's title, and
  `<opened>` is still selected, so it goes on reading `<opened>`'s title while
  the rename has worked perfectly. Assert the pill now; the titlebar becomes
  assertable one step later, once focus moves to the caller. If you would
  rather rename the selected tab outright, name it:
  `tab rename "$opened_id" "My Tab"`.
- **Focus:** `deviceterm tab focus "$caller_id" --json`. **Target the caller,
  not the opened tab.** The opened tab has been selected since it was created,
  so focusing it again moves nothing and every assertion below passes on
  pre-existing state.

  **Do not assert with `tab list --json`'s `current`** — that flag marks the tab
  containing the calling shell, regardless of which tab is selected. Assert on
  the focus receipt's `.window.selectedTabId` and `.tab.selected` instead; they
  must name the caller tab. The window row uses the full stable tab ID.

  Confirm it in AX too: the caller's pill **`value` is 1** and every other
  pill's is 0. Do not reach for `focused`, which is false on all pills.

  **GUI-only focus:** `drive click --ax "deviceterm.tab.$opened_ax"` selects the
  opened tab using its stable tab short ID from the open receipt.
  Prefer the identifier over the title, which collides freely.
- **GUI-only open:** `deviceterm-uitest drive key cmd+t` (New Tab), or
  `drive click --ax "deviceterm.tab.new"` to press the strip's "+" specifically.
  Both open a tab; re-assert the count grew. Since a harness mutation has no CLI
  receipt, take `tab list --all --json` immediately before and after each one and
  require exactly one new full tab `id`; keep it as `<gui>`. Running both
  variants creates two tabs, and cleanup must account for both.

  Do **not** use `drive click --ax "New Tab"` for this. That string matches the
  **Shell** menu item by title and the "+" by description, and the element search
  walks the whole application, so it presses one of them without telling you
  which. The identifier is unambiguous, and the "+" publishes no title at all, so
  the identifier is the only way to name it.
- **Close:** `deviceterm tab close "$opened_id" --mode detach --json`. Assert
  `.closed.resource == "tab"`, `.closed.tab.id == $opened_id`, and `.mode ==
  "detach"`, then re-assert the rendered count dropped.

  **Then close every other tab this scenario opened**, one `tab close <gui>
  --mode detach` per full ID you noted at the GUI-only open step. The
  count should return to its baseline; if it does not, say which tabs you left
  and why. Running every step opens three tabs, one by CLI and one per GUI
  variant, and closing only the first is how an operator's window fills with
  strangers.

  **No modal appears here, even if the tab booted a sim.** `--mode` already
  states the disposition, so there is nothing to prompt for; the CLI hands it
  straight to the close route. The disposition alert belongs to the GUI close
  paths, which carry no mode and therefore have to ask (scenario 5).

  **Never close the caller tab**, and name every target explicitly, per the
  safety rule above. An omitted positional defaults to current, so omitting it
  here closes the tab you are working in and ends the run.

  `--mode` takes **`detach`** or **`shutdown`**. Always pass `detach`: it leaves
  any sims the tab booted running, while `shutdown` stops them, which is the
  thing you may never do to the user's sims without approval. An unrecognized
  value is a usage error.
- **Clean up, on every exit path including an early one.** Two things need
  putting back, and the standing rule to stop the moment you find a bug would
  otherwise skip both, leaving damage you caused as a second finding on top of
  the one you went to report:

  - **The title.** `deviceterm tab rename "$caller_id" ""` puts the caller back
    on automatic titling. The empty name must be quoted so it remains the second
    positional. Closing anything does not undo a manual name.
  - **The tabs.** Close every tab this scenario opened that is still open:
    `<opened>`, and each `<gui>`. On the success path the Close step has already
    taken them; on an early exit it has not, so walk the list yourself. Compare
    the tab count against the baseline as the check.

  This is owed from the first step that opened or renamed anything, not just at
  the end: if you stop early, clean up first, then report. Say so if a cleanup
  step itself fails. Putting back what this scenario deliberately moved is not
  "fixing a bug" and is not what the observe-only rule forbids.

### 2. Pane split + rearrange

- **Setup:** create a throwaway tab and take every handle from its committed
  receipt. Never split the caller's own tab: the GUI close steps below follow
  focus and can escalate to closing the tab.

  ```sh
  work=$(deviceterm tab open --json) || exit 1
  work_id=$(printf '%s\n' "$work" | jq -er '.tab.id') || exit 1
  anchor_id=$(printf '%s\n' "$work" | jq -er '.pane.id') || exit 1
  work_ax=$(printf '%s\n' "$work" | jq -er '.tab.shortId') || exit 1
  deviceterm tab focus "$work_id" --json >/tmp/e2e-work-focus.json || exit 1
  ```

- **Mutate:** split beside the receipt's terminal anchor, then keep the new
  terminal's session ID:

  ```sh
  split=$(deviceterm pane split "$anchor_id" --direction right --json) || exit 1
  split_id=$(printf '%s\n' "$split" | jq -er '.pane.id') || exit 1
  ```

- **Assert:** the split receipt has `.tab.id == $work_id`, `.pane.kind ==
  "terminal"`, and `.pane.tabId == $work_id`. `deviceterm pane list --tab
  "$work_id" --json` lists every terminal, Simulator, and physical-device leaf
  in layout order and includes both `$anchor_id` and `$split_id`. `deviceterm
  tab show "$work_id" --json` carries the same leaves plus the layout tree.
- **Observe (this is the real assertion):** every committed pane's root view is
  an `AXGroup` whose `identifier` is `deviceterm.pane.<kind>.<key>`, such as
  `deviceterm.pane.terminal.4`, `deviceterm.pane.sim.<udid>`, or
  `deviceterm.pane.device.<deviceId>`. A pending placeholder also appears as an
  `AXGroup`, carrying `deviceterm.pane.pending.<n>` and reporting
  `focused:false`. It is not a committed pane and must not be counted against
  `pane list` or `tab show`.

  **The `<udid>` is the canonical lowercase form**, which the GUI interpolates
  verbatim. `xcrun simctl` prints uppercase, so lowercase a pasted UDID or
  compare it case-insensitively.

  Count committed pane nodes in `ax dump`, then cross-check that count against
  the ordered `pane list` rows and the `tab show` layout. Do not include a
  pending placeholder in that comparison because it has no public
  `WorkspacePane`. Use `capture window` to verify the visible split. Count
  **deltas**, not absolutes: only the selected tab's panes are in the view
  hierarchy, and a second window contributes its own.
- **Which pane has focus:** a focused pane node answers `"focused": true`.
  `deviceterm pane focus <pane> --json` returns the committed pane with
  `.focused == true`; confirm the same target in AX. **`AXFocused`
  is per window, not per app:** every open window keeps its own first responder,
  so a second deviceterm window contributes a second focused pane. Assert on the
  identifier you are driving (was it focused, did focus leave it), never on
  "exactly one focused pane". **A pane carrying no `focused` key is not a pane
  without focus:** `AXFocused` does not raise the top-level `unreadable` flag,
  so a failed read reaches you inside an accepted tree looking identical to a
  false. Check the pane's own `"unreadable"` list for `AXFocused` and re-dump if
  it is there.
- **GUI-only split** (the CLI verb above appends; these split the *focused*
  pane, and with a device pane focused the new terminal lands beside it):
  - `deviceterm-uitest drive key cmd+d` → **Split Right**
  - `deviceterm-uitest drive key cmd+shift+d` → **Split Down**
  Each adds one pane node and focuses the new one.
- **GUI-only directional navigation + rearrange** (these are menu key
  equivalents; `pane focus <ref>` covers direct addressing, not these relative
  layout operations):
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

  The tab pill remains `deviceterm.tab.$work_ax` after a terminal closes because
  its identifier is cohort-based, not derived from whichever terminal is
  primary.
- **Clean up, on every exit path including an early one:** the throwaway tab
  usually outlives this scenario. ⌘W closes a pane while ⌥⌘W closes the tab, so
  first test whether the stable full tab ID from the open receipt is still
  present, then close exactly that tab:

  ```sh
  [ -n "$work_id" ] || { echo "no work_id; close nothing" >&2; exit 1; }
  rows=$(deviceterm tab list --all --json) || { echo "tab list failed" >&2; exit 1; }
  if [ -n "$work_id" ] &&
     printf '%s\n' "$rows" | jq -e --arg t "$work_id" 'any(.[]; .id == $t)' >/dev/null
  then
      deviceterm tab close "$work_id" --mode detach --json
  else
      echo "work_id absent or already closed; nothing to close by id"
  fi
  ```

  The non-empty guard is mandatory: an omitted tab positional means current,
  which is the automation tab running the scenario. Check presence before close
  because ⌥⌘W may already have removed the throwaway tab. Never substitute the
  selected tab or an AX pill ID for `work_id`.

  `pane rename` is a committed workspace mutation and can be tested with
  `deviceterm pane rename "$split_id" "Worker" --json`. There is no public
  `pane move`; layout rearrangement stays in the GUI gestures above. Attach a
  Simulator or device with `device attach`.

### 3. Pending-pane lifecycle *(needs a sim; the placeholder is GUI-only)*

The pre-commit loading or failure placeholder is GUI presentation state and has
no public pane ID. While it is visible, `pane list` and `tab show` continue to
report only committed leaves. After the Simulator pane commits but before its
first surface arrives, the pane can show a separate boot overlay. Catching
either loading presentation is opportunistic. The required assertion is that
the final Simulator node and pixels appear.

- **Mutate:** attach a sim so a pane goes through pending (e.g. boot a sim of
  your own; the shim auto-attaches it).
- **Observe (fast):** immediately `capture window`. Before the workspace
  mutation commits, the pending placeholder shows a large `ProgressView`, the
  pane label, and the text **`Connecting…`**. After commit but before the first
  surface, the Simulator pane can instead read **`Booting <label>…`**. `ax dump`
  names either text. **This one is deliberately a race** and stays that way:
  the loading state is what you are trying to catch, so there is nothing to wait
  for first. Report which one you saw, but do not fail the scenario when the
  pane reaches the rendered state before one observation round-trip.

  **`Booting <label>…` has been observed live.** `Connecting…` is the text in
  `PendingPaneView`, but the final E2E run did not catch it. Count that arm only
  when the same dump contains `deviceterm.pane.pending.<n>`; otherwise report it
  as not reproduced.

  **Settle the coexistence advisory before you get here**, per *Receipts commit
  before the CLI returns*. This scenario attaches a pane, which is the trigger,
  so with Device Hub or Simulator.app running the capture you take "immediately"
  can be of the alert rather than the placeholder, and the `ax dump` will name
  the alert's text instead. Suppress it ahead of the run rather than dismissing
  it here, since dismissing costs the race you came for.
- **Observe (after attach):** two steps, because they observe different things.
  First the daemon side, naming the sim you booted by UDID. Run this from a
  terminal in the tab that contains the pane; `wait pane rendering` is
  daemon-side and tab-scoped. The workspace inventory is separate:
  `pane list --tab <tab>` includes every final leaf in that tab.

  ```sh
  SIM=            # the udid of the sim you booted; never the literal "booted"
  [ -n "$SIM" ] || { echo "set SIM to the udid you booted" >&2; exit 1; }
  deviceterm wait pane rendering --pane "$SIM"
  ```

  **Name it explicitly and guard the variable.** An empty `--pane` is not an
  error: the ref falls through to whatever the tab's exported target or sole
  device pane happens to be, so an unset variable silently observes a pane you
  did not mean, or fails ambiguously with two of them. A UDID resolves against a
  device key and survives the sim reboots that reissue short refs.

  **That wait is a precondition, not the thing you are asserting.** It reads the
  daemon's roster, and this scenario's subject is the GUI. The placeholder is
  replaced on the app's own path, after its attach response and reconciliation,
  so `state` can read `rendering` while the window still shows one of those
  loading presentations.
  Capturing on the daemon's word is the cross-observer mistake *Receipts commit
  before the CLI returns* warns about, in a scenario explicitly marked GUI-only.

  So poll the source you are actually asserting on. Bound it, and take a fresh
  `.agents/skills/deviceterm-e2e/helpers/ax-dump.sh` result each time until the
  pane's own node stops being the pending one:
  pane roots are `deviceterm.pane.<kind>.<key>`, so `deviceterm.pane.pending.<n>`
  gives way to `deviceterm.pane.sim.<udid>`. Wait for **that identifier to
  appear** rather than for the pending one to vanish, since the positive form
  cannot be satisfied by a dump that failed or came back short.

  **Lowercase `$SIM` before you build that identifier**, per the case rule in
  scenario 2: a UDID pasted from `xcrun simctl` is uppercase, the identifier
  carries the lowercase form, and an exact poll on the mismatch matches nothing
  and simply times out. `$(echo "$SIM" | tr 'A-Z' 'a-z')`, or compare the suffix
  case-insensitively.

  Only then `capture window` again — the placeholder has swapped to the rendered
  sim pane, and the pixels show the sim.
- **Failure variant (advanced):** if an attach fails, the pane shows
  **`Couldn't connect to <label>`** with **`Retry`** and **`Close`** buttons.
  The failed placeholder remains in its layout slot and stays absent from
  `pane list` and `tab show`.

  Drive `Retry`, or repeat `deviceterm device attach "$SIM" --json`. Both retry
  the existing placeholder instead of allocating another slot. A repeated
  failure returns the daemon's typed error and leaves the placeholder
  available for another retry. Drive `Close` with
  `drive click --ax "Close"` to dismiss it.

  Forcing a failure is hard to do safely. Treat this variant as opportunistic.

### 4. Status item badge *(needs a sim — the daemon's menu-bar item)*

**Pair every `capture status-item` reply with the daemon's own AX tree**, which
publishes the badge directly:

```sh
.agents/skills/deviceterm-e2e/helpers/ax-dump.sh --bundle-id com.deviceterm.daemon
```

Present, it carries one `AXMenuBarItem` whose `title` is the count and whose
`description` is `Booted Simulators`; hidden, it has no menu bar item at all.
That is a second, independent reading of the same number, and it is what makes
`present:false` checkable. On its own that reply is indistinguishable from the
legitimate hidden-at-zero state, so a capture regression looks exactly like a
passing baseline — which is how one shipped. Disagreement between the two is the
finding; report both.

The window the capture matches belongs to **Control Center**, not to the daemon:
macOS hosts every menu-bar extra in its process. Nothing in the reply exposes
that, but don't go looking for a daemon-owned window when diagnosing, and don't
expect a dump of `com.deviceterm` (the app) to carry the badge either.

- **Baseline:** before booting anything, run `capture status-item` with a fresh
  output path. If the reply reports `present:true`, read the badge integer B
  from the PNG. If it reports `present:false`, B is zero and there is no PNG.
  Confirm either reading against the AX dump above.
  Do not derive B by counting `ownerSessionId` fields: ownership attached to a
  protected tab is deliberately hidden from other callers even though its sim
  still contributes to the daemon's badge.
- **Mutate:** boot exactly one sim **you booted** from an unprotected automation
  tab. Use its `devices list --json` row to confirm that this new sim is
  `Booted` and attributed to your session; that checks the test mutation, not
  the workspace-wide badge total.
- **Observe:** run `capture status-item` again with another fresh output path.
  This captures **just** the badge (not a display), so it's
  monitor-independent. Read the PNG; it shows a **monochrome iPhone glyph
  followed by B + 1**. The glyph is a template image, so its color tracks the
  menu bar's appearance — read the integer, not the ink.
- **Verify:** the second reply reports `present:true` and its badge integer is
  exactly B + 1, and the AX dump's `AXMenuBarItem` `title` agrees. Shut down only
  the sim this scenario booted, then capture once more: the badge returns to B.
  For B > 0 that means `present:true` with B in the PNG; for B = 0 the item is
  hidden entirely and the reply is **`{ok:true, present:false}`** with no PNG,
  and the AX dump carries no menu bar item.

  A `present:false` while the AX dump still reports a `title` means the capture
  is failing to find a badge that is drawn. Report both readings rather than
  re-running: it reproduces.

### 5. Close-tab prompt *(two arms; the multi-pane one needs no sim)*

One gesture raises **at most one** prompt. An owned booted sim with no stored
disposition selects the sim prompt, which also lets the user reject the close.
Otherwise, a multi-pane tab uses the multi-pane confirmation.

**Disambiguate on button titles, not on the message.** Both arms use the
literal string `Close this tab?`. Matching on that alone cannot tell you which
one is up, and the two have different safe answers.

**`action-button-1` is positional, not semantic.** Those identifiers are
AppKit's own `NSAlert` defaults, numbered by the order buttons were added;
nothing in this repo sets them. So `action-button-1` is **Close** in the
multi-pane prompt and **Detach (Keep Sims Running)** in the sim-disposition
one. Press by title.

#### 5a. Multi-pane confirm *(no sim needed)*

- **Precondition:** a tab holding **more than one pane** and no owned booted
  sim, with no window, session, or persistent multi-pane suppression active.
  Split a terminal pane and you have one.
- **Trigger:** `deviceterm-uitest drive key opt+cmd+w`. **⌥⌘W, not ⌘W:** ⌘W
  closes the *focused pane*, which is a different gesture entirely.
- **Reads:** message **`Close this tab?`**, informative *"This tab contains N
  panes. Closing the tab closes all of them."*, buttons **`Close`** and
  **`Cancel`**.
- **Dismiss safely:** `drive click --ax "Cancel"`. The tab remains.

#### 5b. Sim disposition *(needs a sim)*

- **Precondition:** a tab that booted a sim **you booted**, with no window,
  session, or persistent sim-close disposition active. This arm ends in a
  disposition prompt over that sim, so it has to be one you own — see the
  device playbook's rule against shutting down a simulator you did not boot.
  The sim must live in a throwaway tab separate from the automation driver,
  because the trigger closes the selected tab if you choose a disposition.
  Establish readiness from the workspace-wide device row plus the selected
  tab's rendered `deviceterm.pane.sim.<udid>` AX node. You may inspect the
  target with `pane list --tab <tab>`, but do not run the tab-scoped
  `wait pane rendering` from the driver and read its empty result as target-tab
  state.
- **Trigger:** same ⌥⌘W. (With the sim pane focused, ⌘W would detach the
  mirror and never raise the prompt.)
- **Reads:** message **`Close this tab?`**, informative *"Detach keeps any
  simulators this tab booted running. Shut Down stops them."*, buttons
  **`Detach (Keep Sims Running)`**, **`Shut Down Sims`**, **`Cancel`**.
- **Dismiss safely:** `drive click --ax "Cancel"`. **Never** press
  `Shut Down Sims` here.

#### Observing either arm

**A sheet is attached, not a sibling window.** These prompts are window-modal
sheets, so `ax dump` shows an untitled **`AXSheet` nested inside** the main
window and the top-level window count stays put. Do not go looking for a
separate empty-titled `AXWindow`; that is what the app-modal alerts elsewhere
look like (scenario 6's quit prompt among them), and it is not this.

Both sheets also carry an **`AXCheckBox` titled `Don't ask again`** and an
**`AXPopUpButton`**. Assert both controls are present, but make the popup-value
assertion from the target window's pre-trigger tab count:

- When another tab shares that window, the initial value is **`For this
  window`**.
- When the target is the window's only tab, window scope is unavailable and the
  initial value is **`Until DeviceTerm restarts`**.

Leave the checkbox off during this scenario so the run does not change the
operator's close defaults.

**`capture window` frames a sheet differently.** Over a sheet it returns the
*whole window scaled down* with the sheet composited on top, so the image's
dimensions track the sheet while its content is the entire window. Over an
app-modal alert it returns the alert alone at natural size. Size an expected
capture against the right case or a pass reads as a failure.

**Pressing the pill's `✕` is a second trigger** via
`drive click --ax "deviceterm.tab.<shortId>.close"`. Address it by identifier:
every pill's ✕ has the title `✕`, so `--ax "✕"` presses whichever one the walk
reaches first, which need not be the tab you meant.

**CLI verbs keep answering while these sheets are up**, because a sheet spins
no nested modal run loop. That is not true of the app-modal alerts that remain
(scenario 6, orphan recovery, the helper prompts): while one of those is up,
workspace verbs go unanswered and the polling advice under "Receipts commit
before the CLI returns" cannot work, since the verbs it tells you to poll are
the starved ones. Poll a fresh `ax dump` instead. `deviceterm doctor` still
answers throughout, because it is daemon-only, which also makes it a poor
liveness proxy for the GUI.

**A verb that times out against a blocked GUI does not land late.** The daemon
stamps a deadline on each back-channel command and the GUI declines an expired
one rather than running it after the fact, so a failed verb stays failed.

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
  attach for a Simulator UDID, physical-device ID, or unique name. Its
  `--json` result is a workspace mutation receipt containing the host `.tab`
  and committed `.pane`.
- **GUI picker:** **`Mirror Physical Device…`** (with the ellipsis glyph) is in
  the **Shell** menu, below Split Down — it creates a pane, so it sits with the
  splits rather than with the Device menu's drive-a-pane items. Open Shell, then
  `deviceterm-uitest drive click --ax "Mirror Physical Device…"`; the device
  picker window appears. **deviceterm has to be frontmost for that press to
  land.** Opening Shell first is not what makes it work — it is how you get there
  with the app already forward. Backgrounded, the same press returns `ok:true`
  and does nothing, so confirm the picker in a fresh `ax dump` instead of
  trusting the receipt (see the `drive` contract above). `capture window` +
  `ax dump` should name the connected devices, and they should match the
  `devices list --json` roster.

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
