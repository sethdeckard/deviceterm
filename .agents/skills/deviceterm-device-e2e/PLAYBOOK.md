# deviceterm device-interaction playbook

Neutral, tool-agnostic instructions for an agent running **inside a deviceterm
tab** that has been asked to drive **the device in a pane** through the
`deviceterm` CLI: touch, hardware input, rotation, and accessibility reads
against a simulator or a connected physical device. The Claude and Codex
`SKILL.md` files point here; this is the single source of truth.

**This is not the skill for testing deviceterm's own chrome.** Window, tab, and
pane furniture, the status item, modal prompts, and the device picker belong to
`.agents/skills/deviceterm-e2e/PLAYBOOK.md`, which drives them through an
out-of-process harness holding Screen Recording and Accessibility.

The split is about instruments, not subject matter. That skill observes pixels
and AppKit accessibility because nothing else can see them. This one needs
neither: the shipped CLI mutates the device and reads its accessibility tree
back, and both halves are deterministic JSON. So this skill requires **no TCC
grants, no harness, no automation grant, and no repo checkout**. Do not import
that playbook's preflight gate; it would refuse a machine that can run
everything here perfectly.

## What you need

- A **booted simulator or connected device attached as a pane, in the
  `rendering` state**. A row in `panes list` is not enough: `state` is one of
  `booting`, `rendering`, `shutdown`, or `failed`, and only `rendering` can
  answer input or accessibility reads. Block on the pane you actually mean:

  ```sh
  DT_PANE=ee15455f-838b-4721-9794-dc51c29b6d8e
  deviceterm wait pane rendering --pane "$DT_PANE"
  ```

  Exit 0 means it is ready. Anything else means stop and read the failure
  rather than proceed and interpret the symptoms — a pane that never arrived
  and a ref that never named one are different problems and exit differently.
  Without `--json` the reason is the human line on stderr; add `--json` when
  you want to branch on the `code`. See *Waiting for a condition*.
- **An app to drive.** SpringBoard has an accessibility tree, but it is sparse
  and its controls move between OS versions. Launch something with real
  controls, **naming the UDID rather than `booted`**:
  `xcrun simctl launch <udid> com.apple.Maps`. This playbook deliberately leaves
  other people's simulators running, so `booted` can resolve to one of theirs
  and you would drive a pane whose app never launched.
- **A shell inside a deviceterm tab**, which is what puts `deviceterm` on your
  `PATH` and what authenticates you. See the sibling playbook's *Invocation
  conventions* for the off-`PATH` fallback and why `.build/debug/deviceterm` is
  the wrong binary.

## Safety rules (do not violate)

- **Never shut down a simulator you did not boot.** Game-dev and other work may
  depend on running sims, and nothing in this playbook needs a clean slate.
  Boot your own, drive it, shut down only that one. `make test-live` does shut
  the fleet down; this skill must never behave like it.
- **Never address deviceterm by bundle id.** Both `open -b com.deviceterm` and
  `osascript -e 'tell application id "com.deviceterm" to activate'` resolve
  through LaunchServices, which cannot tell a dev checkout from an installed
  `/Applications/DeviceTerm.app`. Launching both collides on the one bundle id,
  launchd label, and mach service, and wedges the daemon badly enough to need a
  force quit.
- **Restore what you disturb.** Close the panels you opened, rotate back to the
  orientation you found, and leave the app on the screen it started on. The next
  run's baseline is whatever you leave behind.
- **A line beginning `deviceterm-make: BUSY:` means stop and report.** Do not
  kill the named pid, do not `pkill`, and do not delete a lock directory.
- **You are here to observe, not to build.** `make bundle`, `make test-gui`, and
  `make verify` all `rm -rf` the debug bundle whose `bin/` symlinks put
  `deviceterm` on your `PATH`, so running one from inside a tab destroys your
  own session. If you find a bug, report it and stop.

## Sharing a device with Device Hub

Device Hub (Xcode 27's replacement for Simulator.app) may be open on the same
machine, and it interacts with this playbook's safety rules in one way that
matters.

**Quitting Device Hub shuts down every booted simulator** — not only the ones it
started, not only the one selected in it. A sim booted with `xcrun simctl boot`
and never touched in Device Hub goes down the same. Apple's naming misleads
here: the preference says "started simulators", but read "started" as "booted".
Holding ⌥ swaps Quit for **Quit and Keep Simulators Running**, and that is
one-time rather than a setting that sticks. So a Device Hub quit destroys the
sims this playbook tells you not to shut down, and it is not yours to trigger.

**Video is not exclusive.** Device Hub and DeviceTerm mirror the same phone
concurrently and both keep working, so a mirror that is running is not evidence
you have the device to yourself.

**Touch appears exclusive, and it ping-pongs.** Only one side drives: tap from
the other and nothing happens for a while, then control transfers and the first
side goes dead. **Nothing reports the takeover.** A touch receipt says the HID
report reached the wire, not that the phone acted on it, and there is no
arbitration query to ask. Rotation is not a usable signal either — a relative
rotation reports the orientation it read back as its own target, so it cannot
disagree with itself. So drive the phone from one app. Closing the other is not
required.

Two limits on the above, from `Tests/Manual/device-hub-coexistence.md`, which is
where these come from: only tapping was exercised, so keyboard, button, and
rotation arbitration are **unverified**, and that section has never been run end
to end. Rotation travels the device-control channel while touch travels human
input, so it is entirely plausible they do not share the arbitration at all.
Report what you observe rather than assuming the touch behavior generalizes.

## The mental model

**Mutate with an input verb, then confirm with an accessibility read.** That
read-back is the assertion. The receipt is not.

A receipt reports that the daemon dispatched the gesture, and deliberately says
nothing about what the app did with it. `docs/INTEGRATION.md` states this as
contract. So a tap on the right coordinate, at the wrong moment, against a view
that ignored it, produces exactly the output a working tap produces.

The read-back is what closes that gap: query `ax point` at the coordinate you
tapped, or re-read `ax tree` and compare the label set, and assert the state
actually changed. A switch that went 0 to 1, a panel whose close button
disappeared, a control set that grew.

**A refusal, by contrast, is trustworthy.** A gesture the pane's input lane
refused now fails loudly rather than acking:

```
pane.tap: input lane refused the gesture; nothing was sent, retry
```

Exit 1, and `input.refused` under `--json`. So a successful receipt no longer
hides a send that never happened. It still does not mean the screen changed.

## Invocation conventions

**Allocate a per-run scratch directory.** Several checkouts of this repo run at
once, humans and agents together, so a fixed `/tmp/tree.json` is a collision
between two runs and a false assertion when one reads the other's file:

```sh
DT_DIR=$(mktemp -d)
```

Every scratch path below is written against it.

**Never hardcode a short ref.** They are minted per mount, so a sim reboot
reissues them and a `--pane rpvgzr` baked into a script breaks silently against
whatever pane inherits the ref later. Hold the **UDID** as your durable handle,
since that survives reboots, and derive a short ref from it when a verb needs
one (see the two resolvers below).

For device-control verbs the UDID works directly, matched as a device key,
exactly and case-insensitively:

```sh
DT_PANE=ee15455f-838b-4721-9794-dc51c29b6d8e
deviceterm ax tree --pane "$DT_PANE"
```

Omitting `--pane` works only while the tab holds exactly one device pane. With
two, every pane-targeted verb fails with a disambiguation list:

```
deviceterm: multiple panes in this tab; pass --pane <ref>:
  3eseb1      sim     4800b7e9-05f9-4c84-9c20-cf88857bb161
  rpvgzr      sim     ee15455f-838b-4721-9794-dc51c29b6d8e
```

Exit 1, and `pane.ambiguous` under `--json`. Rows are `<ref>\t<type>\t<key>`,
where type is `sim` or `device` and the key is a sim UDID or a physical
`deviceId`. They are **sorted by paneId**, which is a UUID you never see in the
listing, so the order is arbitrary as far as you are concerned. Treat it as a
lookup aid, never as an ordering.

**A UDID does not work on every verb.** Two different resolvers are in play:

- **Device-control verbs** (`tap`, `swipe`, `long-press`, `pinch`,
  `app-switcher`, `button`, `key`, `text`, `rotate`, `crown`, `ax *`) resolve
  `--pane` **locally against `panes.list`** through `PaneRefResolver`, which has
  a device-key tier. A UDID works.
- **Workspace verbs** (`pane close`, `pane rename`, `pane info`, `pane move`)
  send the ref to the GUI instead, classified by `CLICommands.parsePaneRef`,
  which has only two branches: UUID-shaped becomes a **`paneId`**, anything else
  becomes a `shortId`. A sim UDID *is* UUID-shaped, so it is sent as a paneId
  and matched against a pane's `paneId`, which it never equals.

**Of those four, only `pane close` and `pane info` are implemented, and both are
simulator-only.** No ref type changes that. The GUI resolves them through
`resolveSimPane`, which walks a tab's `simPanes`; physical-device panes live in
a separate `devicePanes` collection that this resolver never looks at. So both
fail with `intent.notFound` against a device pane given a perfectly correct
shortId or paneId, and there is no CLI route to closing one: that is the pane's
own close control in the GUI.

Device panes still appear in `panes list`, typed `device`, so a ref you resolve
there is not necessarily a ref a workspace verb can use.

`pane rename` and `pane move` fail for a different reason and on every pane
alike: they throw before reaching any resolver. See *Known broken*.

So `deviceterm pane close --pane <udid>` does not close that pane. **It fails
loudly**, with `intent.notFound` and a nonzero exit, because the GUI looks for a
pane whose `paneId` equals your UDID and finds none. That is a clean failure,
not a silent mistarget.

Resolve a workspace-verb ref at run time instead:

```sh
DT_REF=$(deviceterm panes list --json | jq -r --arg u "$DT_PANE" '
  [ .[]
    | select((.udid | ascii_downcase) == ($u | ascii_downcase))
    | (.shortId // .paneId) ]
  | if length == 1 then .[0] else empty end')
[ -n "$DT_REF" ] || { echo "no unique pane for $DT_PANE" >&2; exit 1; }
```

**Every part of that guard earns its place.**

- The comparison is **case-insensitive** because `panes list` emits canonical
  lowercase UDIDs while `xcrun simctl list devices` prints uppercase, so a
  `DT_PANE` copied from simctl misses on an exact compare.
- It falls back to **`paneId`** because `shortId` is absent against a daemon
  predating the identifier model, and a workspace verb takes a paneId perfectly
  well: it is UUID-shaped, so `parsePaneRef` classifies it as one and the GUI
  matches it directly. Insisting on `shortId` would abort on exactly the skew
  this playbook tells you to tolerate elsewhere.
- The **emptiness check** is the one that prevents damage. `--pane ""` is not an
  error: `parsePaneRef` treats empty as `current`, so a failed lookup silently
  retargets the verb at whichever pane is current. This is the only quiet
  mistarget in the section, and on `pane close` it closes the wrong pane.

**Use `--json` for every assertion**, and know which fields are guaranteed. The
receipt shape is per verb, and each verb has a required core plus fields that
can legitimately be absent. A nil field is **omitted entirely** rather than
emitted as null, so "key missing" and "value null" are not the same signal.

`ok`, `udid`, and `paneId` are on every input receipt. `shortId` is on all of
them too but may be absent against a daemon predating the identifier model.
Beyond that:

| verb | always present | may be absent |
|---|---|---|
| `tap` | `x`, `y`; `matchCount`, `elapsedMs` when a selector resolved it | `role`, `label`, `identifier` on a selector tap; all five on a coordinate tap |
| `app-switcher` | `x`, `y` (the gesture's fixed start point, not yours) | |
| `long-press` | `x`, `y` | `durationMs` |
| `pinch` | | `durationMs` |
| `swipe` | | `dispatched`, `steps`, `durationMs` |
| `button` | `button` | |
| `key` | `keyCode`, `down` | |
| `text` | `bytes` | |
| `crown` | `delta` | `velocity`, `durationMs` |
| `rotate` | `targetOrientation`, `observedOrientation` | exactly one of `orientation`, `direction` |

**A missing required field is a failure; a missing optional one is not.** So a
`tap` receipt without `x` is a finding, while a `long-press` receipt without
`durationMs` just means you omitted the flag: the receipt echoes what you asked
for, not the default the daemon applied. The same goes for `swipe`'s three,
which are all absent against a daemon predating the dispatched echo, reachable
mid-Sparkle-update.

`text` reports `bytes`, a UTF-8 count, and deliberately never the string, since
receipts get piped to logs and typed input can carry secrets.

`dispatched` is worth reading when present: a duration below the one-frame floor
collapses to a tap-shaped wire, and `dispatched: "tap"` is how you catch that
promotion.

**Failures are typed too.** Under `--json` a failure prints an envelope on
**stdout**, keys sorted, while stderr keeps the human diagnostic and the exit
status stays nonzero:

```json
{"error": {"code": "pane.notFound", "message": "no device pane in this tab"}}
```

**Assert on `code`, never on `message`.** The code is stable; the wording is
not. **`details` is additive and its keys are individually optional**, so read
each on its own rather than assuming a code implies a set. `rotate.unconfirmed`
is the one to watch: a request refused admission carries no `deadlineMs`,
because nothing was ever dispatched to have a deadline, and a *relative*
`left`/`right` request refused that way carries no `targetOrientation` either,
because no absolute target had been resolved yet. An error relayed from the
daemon carries its numeric `rpcCode`.

The envelope appears only when you asked for JSON. `ax tree`, `ax point`, and
`ax sweep` emit JSON by default and so produce one without the flag; every other
verb, **`wait` included**, needs an explicit `--json`.

**That default belongs to the parsed command, not to the verb's name.** An
invocation refused during parsing — bad arity, an unparseable number, a
coordinate outside the unit range — never becomes an `ax` command at all, so it
prints its usage block to stderr and no envelope, even under a verb that would
otherwise have emitted one. `deviceterm ax point 5 5` is `cli.invalidUsage` with
nothing on stdout unless you passed `--json`.

**`events` is the exception that produces no envelope at all.** Its connection,
authentication, and subscription failures write a human line to stderr and exit
directly, without going through the renderer the table below describes. Do not
watch stdout to learn why a stream never started.

**Do not treat any list of codes as exhaustive, this one included.** The code
type is an open wrapper rather than a closed enum, its constants are spread over
`CLIErrorCode.swift` and `CLIErrorCode+Rotate.swift`, and a daemon error's own
`intent.*` code passes through verbatim without appearing in either file. Branch
on the codes you handle and let the rest fall through as unrecognized.

The ones this playbook's scenarios reach:

| code | exit | meaning |
|---|---|---|
| `pane.notFound` | 1 | no pane matched the ref |
| `pane.ambiguous` | 1 | the tab holds several panes and you named none |
| `pane.unavailable` | 1 | the pane lost its live backend |
| `input.refused` | 1 | the pane's input lane refused; nothing was sent |
| `rotate.unconfirmed` | 1 | the rotation was not confirmed — either refused admission and never dispatched, or dispatched and never observed to land |
| `rotate.confirmationUnsupported` | 1 | this daemon or backend cannot confirm one |
| `wait.timeout` | **124** | a wait's overall deadline expired |
| `wait.inconclusive` | 1 | a wait could not settle the question |
| `wait.unsupported` | 1 | this pane cannot answer that wait |
| `cli.invalidUsage` | 1 | the arguments did not parse |

`transport.*` covers a daemon that is unreachable, slow, or interrupted, and
`intent.*` codes pass through from the daemon unchanged.

## Waiting for a condition

**Four conditions have a CLI verb. Use it rather than a poll loop.**

```sh
deviceterm wait pane rendering --pane "$DT_PANE"
deviceterm wait ax --label "Map Modes" --match contains --pane "$DT_PANE" --json
deviceterm wait orientation landscape-left --pane "$DT_PANE"
deviceterm wait surface quiescent --pane "$DT_PANE"
```

Each blocks until the condition holds or the deadline expires. The first probe
is immediate, and the 100 ms cadence is a sleep *between* probes rather than a
period they are issued on, so a slow probe spaces the next one further out
instead of overlapping it. `--timeout` defaults to **30000 ms**.

**Each sub-verb reads its own flags beyond `--pane` and `--timeout`, and passing
one to a wait that does not read it is a usage error rather than a flag that
gets ignored.** That refusal is worth knowing about because the silent version
of it used to produce a clean false pass: `wait pane rendering --label Save`
waited for the pane, never looked for the label, and exited 0.

**`wait.timeout` is the only outcome that exits 124; every other failure exits
1.** So a nonzero exit says nothing on its own — read the `code`, which means
running the wait under `--json`, since a bare `wait` prints only the human
diagnostic. What the codes separate is *why* the question is still open:

| exit | code | meaning |
|---|---|---|
| 0 | | the condition held; `--json` carries the observation |
| 124 | `wait.timeout` | the deadline expired with the question still open |
| 1 | `wait.inconclusive` | the observation could not support the claim |
| 1 | `wait.unsupported` | this pane cannot answer this wait at all |
| 1 | `wait.unreachable` | matches existed, none usable as a coordinate target |
| 1 | `wait.ambiguous` | several eligible matches that do not nest |
| 1 | `pane.notFound` | the ref never named a pane, or the pane vanished |

**A wait that failed is not necessarily a wait that timed out.** A `--pane` ref
that never resolves is reclassified at the deadline into `pane.notFound`, exit
1, keeping the timeout's `elapsedMs`, `timeoutMs`, and `attempts` in `details`.

`--pane` takes the same refs the input verbs take. A named pane that has **not
appeared yet is pending, not `pane.notFound`**, so a wait may start before the
pane exists; a pane that disappears mid-wait fails as `pane.notFound`. An
ambiguous ref fails on the first probe: a wait retries absence, never ambiguity.

**`wait pane <booting|rendering|shutdown|failed>`** is the readiness gate from
*What you need*.

**`wait orientation <orientation>`** requires **two consecutive** probes that
agree on the orientation *and* on stable positive surface dimensions, so a
half-applied rotation does not satisfy it. It reads the pane's *confirmed*
orientation, which is published by simulator display observation and by
physical-device rotation replies — **nothing polls a handset's attitude**, so it
cannot see hardware turned by hand. Scenario 2 covers what it is for, now that
`rotate` confirms its own landing.

**`wait surface quiescent [--settle <ms>]`** waits for the rendered surface to
stop changing, default 500 ms, and zero is legal — it then means one unchanged
observation rather than a window of stillness. It is the condition to wait on
after a change with no element to wait for: a theme flip, an animation settling.

**It is a settle, not a proof that anything happened.** A screen that has not
started changing yet is every bit as still as one that has finished, so used as
a post-mutation barrier it can return before the transition it was meant to
outlast even begins. That is fine when the assertion is a separate read-back,
and not fine as the assertion itself. When you know what should appear, waiting
for that element is the stronger instrument.

Two further things it is not. **It is not a first-frame wait**: a pane with no
surface yet is pending rather than quiescent, and `wait pane rendering` is what
waits for one. **It is not a rotation signal**: surface dimensions do not swap
when a device turns, so `wait orientation` is what confirms that. Stillness here is the
surface being *unchanged*, compared as a whole value and never as a delta,
because the increment is backend-dependent and means nothing across both kinds
of pane.

**`wait ax`** is the element-discovery path; see *Finding an element to operate*.
`--match contains` folds case locale-independently; `--role` is always exact and
case-sensitive in both match modes. `--value` narrows to an element whose own
value matches, under the same `--match` mode — typing into a field puts the text
in its value rather than its label, so `--label` names the field and `--value`
asserts what it now reads. It is a filter, not a selector: it ANDs onto
`--identifier` or `--label`, and never matches a non-string value, because the
comparison is textual. `--step` and `--budget` require `--source sweep`, and that
sweep's budget is reduced to the time remaining before the overall deadline —
**so the budget shrinks as the wait runs on**, and a late probe can be granted
less than its grid costs, truncate, and end the wait on `wait.inconclusive`
rather than reaching the deadline at all.

**`--state <present|absent>`** chooses the direction, `present` by default.
`absent` reports the condition `ax.disappears` and is the assertion a check
usually wants: the spinner went, the banner cleared. It cannot be combined with
`--print center`.

**Either direction can be satisfied by the state you started in**, which is the
standing trap for every wait in this section. An `absent` wait passes instantly
against something that was never there, and a `present` wait passes instantly
against something that was already there — in both cases before your mutation
could have done anything. A wait is only evidence of a change when you
established the opposite first, which is why the scenarios below record a
baseline and prove their marker absent before typing it.

**The two directions fail differently, and the asymmetry is the whole point.**
A match settles presence whatever the observation missed, because presence is a
claim that *something* is there. Absence claims something about *everything*, so
an observation that did not see the whole pane cannot support it. Concretely:
still seeing the element at the deadline is an ordinary `wait.timeout`, since a
sighting settles the question however much went unseen, while an incomplete
observation with nothing matching reports what it could not see.

With `--json` the receipt lists up to 20 matches under `matches`, with
`matchCount` for the true total and `matchesTruncated` present only when the
list was trimmed.

### An AX wait reports what it could not see

**A match wins over any incompleteness.** Nothing below fires while something
matched, in either direction, so read these as answers to "nothing matched" and
never as reasons a match was withheld.

With nothing matched, the wait reports the observation's own shortfall rather
than a bare deadline, carrying the daemon's `note` and `noteCode` in `details`.
**When it reports depends on whether probing again could help:** it reports on
the probe that saw it when it could not, and at the deadline when it could.

| observation | code | reported |
|---|---|---|
| enumeration unsupported on this device family | `wait.unsupported` | on sight |
| a truncated sweep | `wait.inconclusive` | on sight |
| a tree the daemon knows is incomplete | `wait.inconclusive` | at the deadline |

The middle row is terminal by policy rather than by nature: this wait never
varies the step or budget you asked for, and caps each probe's budget at the
time left, so no later probe gets more than the first. A fresh `ax sweep` with a
coarser `--step` or a larger `--budget` may well finish — that call is yours to
make. The last row is retried precisely because the note does not say *why* the
tree was short, so a later probe may see a complete one.

**`wait.unsupported` has two origins and only one of them is about the walk.**
The device-family case above carries a `noteCode`; a pane whose
`capabilities.accessibility` is false carries none and reports that
accessibility observation is unavailable. `details.noteCode` is what tells them
apart, and only the first is helped by trying another `--source`.

**An unnoted tree is not a tree known to be complete.** The daemon proves an
omission by hit-testing a point the walk left uncovered; one sample can
establish that something is missing and cannot establish that nothing is.

**Two things `wait` does not do.**

- **It does not cancel anything.** A wait that returns 124 stops waiting; the
  daemon-side work already in flight runs to completion. See *Known broken*.
- **It does not observe deviceterm's own chrome.** Tab counts, window state,
  titles, and the AppKit tree belong to the sibling playbook and its harness.

**The shell builtin `wait` is a different command.** Scenario 5 uses it on
background job pids, deliberately, and must stay as it is.

## The coordinate contract

**Every coordinate-bearing verb takes normalized coordinates in displayed
space.** `(0,0)` is the top-left of what you see in the pane, whatever the
orientation. The daemon rotates into the device's native surface on your behalf,
for input and for accessibility queries alike.

**So compensate for nothing.** No transposition, no manual rotation, no
per-orientation special case in your script. Portrait is the identity transform,
which is exactly why a portrait-only run proves nothing about this: read the
next section before concluding a landscape check passed.

**The daemon computes the coordinate for you.** Every usable node carries a
`normalizedCenter`, an `{x, y}` pair in that same displayed 0...1 space, ready
to hand straight to `tap`, `swipe`, `long-press`, `pinch`, or `ax point`. A
node's `frame` stays in displayed *points* and is there for size checks, the
44 pt hit-target guideline among them, not for you to divide.

**A node without a `normalizedCenter` is a successful partial result, not an
error.** The daemon omits the key when the root has no positive finite width and
height, when the node itself lacks a finite origin or positive finite
dimensions, or when the computed centre lands outside `0...1`. So select on the
key's presence rather than validating a number you worked out yourself.

**A coordinate outside the range is refused, not dispatched.** `tap`, `swipe`,
`long-press`, `pinch`, and `ax point` reject anything outside an **inclusive**
0 through 1, along with non-numeric, NaN, and infinite values, as
`cli.invalidUsage` and exit 1, before any daemon round-trip. Both endpoints are
accepted, matching the range the daemon emits, so every centre it produces is a
coordinate these verbs take.

That guard closed a false pass this playbook's own doctrine warns about:
`deviceterm tap 5 5` used to return `ok`, exit 0, and touch nothing — a receipt
indistinguishable from a working tap. **It does not make a frame value safe.** A
small frame number passes the range check and taps the wrong place; only the
out-of-range ones are caught. That is the argument for `normalizedCenter` rather
than a frame value, and the guard is a backstop, not a substitute.

### A worked example, in two orientations

The Maps *Map Modes* button on an iPhone 17, read and tapped in each
orientation:

| | root frame | node frame | `normalizedCenter` |
|---|---|---|---|
| `landscape-right` | 874 x 402 | x 764, y 26, w 48, h 48 | `0.901601 0.124378` |
| `portrait` | 402 x 874 | x 338, y 382, w 48, h 48 | `0.900497 0.464530` |

The last column is read off the node, not worked out from the two before it.
Both resolved through `ax point` and both tapped the button, untransformed.

**What this pair shows is that the recipe works untransformed in both
orientations.** That is the claim worth making, and both taps landed.

**What it does not show is anything about the rotation transform**, and the
numbers are a trap if you read them that way. The centre moves from (362, 406)
to (788, 50) in raw points, which is not the rigid rotation of a fixed control:
Maps relaid its own interface. Two effects are stacked here, the changed root
and the app's reflow, and you cannot separate them from these numbers alone.

The operational rule is the same either way. **Re-read the tree after every
rotation**, and take the `normalizedCenter` off the node you just read. A
coordinate cached from another orientation is stale, whether it went stale
because the root swapped or because the app moved the control.

### `ax point` answers under `element`, not `tree`

```
ax tree   ->  {"tree":    {...}}
ax sweep  ->  {"tree":    {...}}   # synthetic root, role AXSweepRoot
ax point  ->  {"element": {...}}
```

A `.tree.label` path against `ax point` yields `null`, which reads exactly like
a coordinate that resolved nothing. It has cost a caller a full round of
debugging a mapping failure that never existed. Check the key before you
conclude a miss.

**`ax sweep`'s root frame is a placeholder** (`0,0,1,1`), not the screen's, and
it is the one node that never carries a `normalizedCenter`. Its children do:
`ax point` and `ax sweep` both scale against the real frontmost tree the daemon
reads during preflight, so no caller ever computes a scale.

**The real screen comes back as `rootFrame`**, in displayed points, on `ax point`
and on the `ax sweep` root — once per response, never on a child. `ax tree` does
not carry it, its own root `frame` being the scale already. Multiply a
`normalizedCenter` by `rootFrame.w` and `.h` to get displayed points back
without a second `ax tree`.

It is omitted rather than defaulted when the preflight root had no usable frame,
because a synthesized `1 x 1` reads exactly like a genuine one-point screen.
**Check for it on its own**: a root with usable dimensions but an unusable
origin still produces `normalizedCenter` for its nodes while `rootFrame` stays
absent, so its absence is not evidence that the response carries no centres.

## Finding an element to operate

**To tap something you can name, name it.** `tap` takes `wait ax`'s selector,
blocks until it resolves one target, and taps its centre:

```sh
deviceterm tap --label Continue --match contains --pane "$DT_PANE"
```

No coordinate crosses the shell. `tap` and `wait ax --print center` make the
same selection through one shared code path, so the two cannot come to disagree
about which element a query means.

**A refusal sends no tap.** `wait.unreachable`, `wait.ambiguous`, and
`wait.inconclusive` each end the command with nothing dispatched, so a query
that named the wrong thing costs an exit code rather than an input you cannot
take back. A deadline with complete observations and nothing matching is
`wait.timeout` and exit 124, also with no tap.

**What the selection establishes is narrower than it looks.** Among the matches
this query returned, these are the ones that are non-presentational and carry a
`normalizedCenter`. That is all. It says nothing about whether the element is
enabled, unobscured, or hit-testable: a caption carries a centre and is
perfectly reachable, and is excluded by policy so it never stands in for the
control it labels. Do not read a successful tap as proof the element was
actionable — that is what the read-back is for.

The two forms do not mix. Two positionals *and* a selector is a usage error, not
a precedence rule, and a coordinate tap carrying a selector-only flag is refused
rather than quietly ignoring it. Under `--json` a selector tap adds `matchCount`
and `elapsedMs`, and adds `role`, `label`, and `identifier` **only for the
attributes the element actually carried** — each is omitted otherwise, so do not
require all three. A coordinate tap omits all five and keeps the receipt shape
it always had.

**`--print center` is for the other coordinate verbs.** No selector form exists
on `swipe`, `long-press`, `pinch`, or `ax point`, so those still go through a
coordinate:

```sh
read -r x y < <(deviceterm wait ax --label Continue --match contains \
                  --print center --pane "$DT_PANE")
deviceterm long-press "$x" "$y" --pane "$DT_PANE"
```

It writes a bare `x y` at six decimal places and nothing else, refuses with the
same two codes rather than guessing, and writes nothing when it does. It cannot
be combined with `--json`, nor with `--state absent`.

**To inspect the ranked matches** rather than act on one, read the observation.
`matches` is capped at **20** entries with `matchCount` carrying the true total,
and ranking runs *before* that truncation, so the 20 you get are the 20 highest
ranked rather than the first 20 encountered. Presentational roles rank last,
entries lacking a `normalizedCenter` next to last, then smaller frames first,
with discovery order as an explicit tie-break. A role the ranking does not
recognize sorts as actionable. **The order is a heuristic**: `matches[0]` may
carry no `normalizedCenter` at all, which is exactly why `--print center` and
`tap` do the selecting.

**To enumerate what is on screen**, rather than find something you can already
name, read the tree and select on the key:

```sh
deviceterm ax tree --pane "$DT_PANE" > $DT_DIR/tree.json
jq -r '
  [ .tree | recurse(.children[]?) ]
  | map(select(.normalizedCenter))
  | .[]
  | [ .normalizedCenter.x, .normalizedCenter.y,
      (.role // ""), (.label // ""), (.identifier // "") ]
  | @tsv
' $DT_DIR/tree.json
```

**Selecting on `normalizedCenter` is also the bounds check.** Maps'
dismiss-popup group carries a frame of `x -402, y -874, w 1206, h 2622`:
negative origin, roughly three times the root in both axes. Its centre falls
outside `0...1`, so the daemon omits the key and the node drops out here with no
filter of your own. A selector written against `frame` still picks it up, and
picks it up first. Filter on `role` as well when a screen has several such
wrappers.

**Pick a control you can watch react**, not a static label. A tap on a `Text`
node produces a clean receipt and no observable change, which is
indistinguishable from a broken coordinate.

## `ax sweep`: density and budget

`ax sweep` grid-walks the screen with point queries and aggregates unique
elements. Use it when `ax tree` comes back empty, which on watchOS is the normal
case rather than a fault.

**The step is the sample spacing**, so a control narrower than it can fall
between samples and read as absent. At 0.08 the samples sit 32pt apart on a
400pt-wide screen, wide enough to skip a 25pt toolbar button. If you can see an
element that the sweep did not find, sweep finer before concluding it has no
accessibility node.

A completed sweep makes `ceil(1/step)^2` queries: 400 at the 0.05 default, 2500
at the 0.02 floor. Steps outside `[0.02, 0.5]` are clamped silently, so read
`step` back from the result.

**`--budget <ms>` bounds how long the daemon spends scheduling those queries**,
10000 by default and 60000 at most, clamped as silently as `step` and echoed as
`budgetMs`. Whether a given grid fits inside a given budget depends on the host
and the device, so **read `truncated` rather than predicting it**:

```sh
deviceterm ax sweep --step 0.02 --pane "$DT_PANE" \
  | jq '.tree | {step, budgetMs, sweepedPoints, truncated, note, noteCode}'
```

`truncated: true` means part of the grid went unqueried and `sweepedPoints`
counts what it reached. **An element missing from a truncated sweep is not
evidence it is off screen.** A truncated sweep also carries a `note` naming what
to try and a `noteCode` naming it in one token; a completed one carries neither.

**Branch on `noteCode`, show `note`.** The two truncation notes differ only in
prose and share one error code, so the token is the only thing that separates
them programmatically. The set is closed and lives in
`Sources/DaemonProtocol/Accessibility/AXTreeNote.swift`, which is where to look
rather than trusting a list here to have kept up; today it holds the two
truncation tokens, one for a walk the device family does not support, and one
for a tree the daemon has proved incomplete. A token you do not recognize still
decodes as a plain string.

Two things that surprise people:

- **A sweep can truncate for reasons that have nothing to do with your step.**
  The budget covers the wait for the pane's serial accessibility queue, and that
  wait is charged from when your request arrived, not from when it reached the
  front. A sweep queued behind a long one can come back `sweepedPoints: 0` with
  its whole budget already spent. Retry when the pane is quieter.
- **At the ceiling the advice changes.** A sweep that truncates at
  `budgetMs: 60000` comes back `ax.sweepTruncatedAtMaxBudget` rather than
  `ax.sweepTruncated`, and its note never suggests `--budget`, because there is
  no larger budget to ask for. Coarsen `--step` or retry.

## Scenario library

Each scenario: **mutate -> read back -> assert the state changed**. Record a
baseline before you mutate; every assertion below is a delta.

### 1. Round-trip a control (the flagship)

The one that matters, because it is the whole contract in four commands, and
because a false pass here looks exactly like a real one.

```sh
deviceterm ax tree --pane "$DT_PANE" > $DT_DIR/before.json
deviceterm tap --label "Map Modes" --match contains --pane "$DT_PANE" --json
deviceterm wait surface quiescent --pane "$DT_PANE"
deviceterm ax tree --pane "$DT_PANE" > $DT_DIR/after.json
```

**The third command is not optional.** `tap` waits for its *target* and then
returns once the tap is dispatched; it does not wait for whatever the tap
causes. An `ax tree` read immediately after it can capture the screen the tap
was meant to change, which reads as "the tap did nothing". Settle first. When
you know what should appear, `deviceterm wait ax --label Satellite` is the
stronger form, because it asserts the expected transition instead of merely
waiting for motion to stop.

Assert two things, in order:

1. **The tap receipt is `ok`**, and what it says about the element agrees with
   what you meant. **Compare only the fields present**: `role`, `label`, and
   `identifier` are each omitted when the element carried no such attribute, so
   a selected element legitimately arrives with only one of them, and requiring
   all three turns a good round-trip into a false failure. `matchCount` above 1
   means the query was looser than you thought even though selection resolved
   it — worth tightening with `--role` or `--identifier` before you trust the
   scenario.
2. **The label set changed.** Diff the labels in `$DT_DIR/before.json` against
   `$DT_DIR/after.json`. **This is the assertion**; step 1 only supports it.

A real run of this looked like: `Card controller, Dictate, Locations, Map, Map
Modes, Maps, Tracking, profile` becoming `Close, Driving, Explore, Labels, Map,
Map Modes, Maps, Satellite, Traffic, Transit`. Step 2 passing while step 1 names
something unexpected means you tapped something, just not what you meant to.

**Run it once by coordinate too**, because the two forms exercise different
halves of the contract and only this one tests the coordinate mapping this
playbook exists to check:

```sh
deviceterm ax tree --pane "$DT_PANE" > $DT_DIR/before-coord.json

# Derive the coordinate here, every run. A literal pair is only ever right for
# the device, orientation, and layout it was read on, and scenario 2 runs this
# in three orientations.
read -r cx cy < <(deviceterm wait ax --label "Map Modes" --match contains \
                    --print center --pane "$DT_PANE")

deviceterm ax point "$cx" "$cy" --pane "$DT_PANE" | jq '.element'
deviceterm tap "$cx" "$cy" --pane "$DT_PANE" --json
deviceterm wait surface quiescent --pane "$DT_PANE"
deviceterm ax tree --pane "$DT_PANE" > $DT_DIR/after-coord.json
```

`ax point` must return the element you took the coordinate from: compare `role`
and `label`, and `identifier` when the node carries one. A different element
means you took the coordinate off a different node than you meant to, and `null`
means check you read `.element` and not `.tree`.

**That check is not the assertion either.** It proves the coordinate resolved to
the right element *before* the tap, and the receipt proves only dispatch, so
between them they still cannot tell a landed tap from a touch the screen
ignored — which is precisely the failure the Device Hub section describes, where
the other app holds touch and nothing reports it. Diff the label sets here too.

### 2. Orientation coverage

**Portrait alone proves nothing**, because it is the identity transform for
every rotation in the system. A run that only covers portrait cannot distinguish
a correct implementation from one that rotates nothing at all.

Run scenario 1 in each of:

```sh
deviceterm rotate portrait --pane "$DT_PANE" --json
deviceterm rotate landscape-left --pane "$DT_PANE" --json
deviceterm rotate landscape-right --pane "$DT_PANE" --json
```

**`rotate` returns only once the target orientation has been confirmed**, so the
receipt is itself an assertion. It carries `targetOrientation` and
`observedOrientation`, both required on success, and on success they agree.

**What "confirmed" means differs by backend, and the difference is the whole
point of running this scenario on both.** A simulator confirms against the
*presented display* — the same observation that drives rendering and coordinate
mapping — so an app that holds its own orientation and leaves the display where
it was **fails** here with `rotate.unconfirmed`. A physical device confirms
against the *relay's reported device attitude* instead, which is the handset's
own sense of which way up it is. Those are not the same claim: an
orientation-locked app on hardware can leave the display in portrait while the
device reports landscape, and the rotation confirms anyway. **So on hardware a
confirmed rotation is not evidence the display moved** — re-read the tree and
check the root frame if that is what you need.

An absolute rotation on hardware is also not atomic: it converges by issuing
relative steps and reading each reply back, so the device passes through
intermediate orientations on the way.

So there is no settling window to poll after your own `rotate`, on either
backend, and no need for `wait orientation` there. **`wait orientation` also
cannot see a handset someone turns by hand.** The confirmed orientation it reads
is published by simulator display observation and by physical *rotation command
replies*; nothing polls a device's attitude on its own, so a hand rotation
publishes nothing and the wait either times out or returns immediately on the
stale value it already held. Use it for a simulator whose app rotates itself,
not as a way to notice hardware being picked up and turned.

**Re-read the tree after each rotation, and let it tell you what happened.** The
root frame is the observation, not a formality: on a quarter turn that the
display actually took, `w` and `h` transpose and normalized centres move with
them — though not all of them, since a node at the exact centre keeps `0.5,
0.5`, so one coordinate holding still is not evidence the rotation did not
happen. Neither half of that is unconditional. A half turn leaves the
dimensions equal and moves only the content, and on hardware a rotation can
confirm against the device's attitude while an orientation-locked display never
turns at all — which is exactly the case above where the receipt agrees and the
root does not move. A root that did not change is a result to report, not a
failed read to retry.

**Do not schedule `portrait-upside-down` on a simulator.** The device
orientation moves and the **display refuses**: the framebuffer keeps portrait
dimensions and the accessibility tree is identical to portrait. Verified on
iPhone 17 and iPad mini, in Maps and on SpringBoard, via the direct set and via
two `rotate left` steps. `Sources/CoreSimulatorBridge/as-tested.md` records the
same split, and its `uiOrientation` table has rows only for portrait,
landscapeLeft, and landscapeRight. Reaching it needs physical hardware.

**What the command now returns is a different question from what the display
does, and only the second half was observed.** Those runs predate rotation
confirmation, when `rotate` acked on dispatch and this returned `ok` with exit
0. Confirmation on a simulator watches the display, which is the thing that
refuses here, so the request should now go unconfirmed and fail — the same arm
as the orientation-locked app above. **That follows from the confirmation path
rather than from a run**, so treat a differing result as a finding about this
note rather than about the device.

**`rotate left` and `rotate right` are relative**, and they now resolve against
the latest *confirmed* orientation rather than the last one DeviceTerm was told
to command, so an app that rotates itself no longer leaves that base stale. The
absolute forms still read better in a scripted run, because they name where you
end up instead of where you started.

### 3. App Switcher

```sh
deviceterm app-switcher --pane "$DT_PANE" --json
deviceterm wait surface quiescent --pane "$DT_PANE"
deviceterm ax tree --pane "$DT_PANE" | jq -r '[.tree | recurse(.children[]?)] | map(.label // empty) | .[]'
```

**Settle before reading.** The switcher animates in, and a tree read taken while
it does shows the app you started from — indistinguishable here from a gesture
the recognizer never armed.

This is an edge-tagged system gesture, not a content swipe, and the daemon
derives the edge from the pane's current orientation. Confirmed in portrait and
both landscape orientations; upside-down has no edge value that arms the
recognizer. A physical device that does not support the edge gesture falls back
to a consumer-HID Home double-press.

Assert on the tree, not on the receipt.

### 4. Hardware input

These verbs are the easiest place in the playbook to fake a pass, because each
one dispatches cleanly into a screen that ignores it. **Keystrokes go wherever
focus already is**, and nothing in the receipt knows whether that was a text
field or nothing at all. So every step below names its own read-back.

**`button home`** leaves the app:

```sh
deviceterm button home --pane "$DT_PANE"
deviceterm wait surface quiescent --pane "$DT_PANE"
deviceterm ax tree --pane "$DT_PANE" \
  | jq -r '[.tree | recurse(.children[]?)] | map(.label // empty) | .[]'
```

The settle matters as much here as anywhere: the dismissal animates, and a tree
read during it still carries the app's own labels, which is exactly the "the
button did nothing" reading you are trying to rule out.

Assert the app's controls are **gone**, not that anything specific appeared:
SpringBoard's own labels vary by OS version and Home Screen contents, while the
disappearance of the label set you recorded before pressing is unambiguous.

**`text` needs focus, and a coordinate is not a durable handle on the field.**
Focusing it raises the keyboard, which reflows the layout, so a coordinate that
was right before the tap may point at something else by the time you read back.
Name the field instead — `tap --identifier` re-resolves it at tap time, which is
the whole reason to prefer it here — and pick a field that carries an
identifier:

```sh
FIELD=SomeField.Identifier   # from an ax tree read, not guessed
MARK=zzq7                    # a marker, not a word the field might already hold

read_field() {
  deviceterm ax tree --pane "$DT_PANE" \
    | jq -r --arg id "$FIELD" '
        [ .tree | recurse(.children[]?) | select(.identifier == $id) ]
        | if length == 1 then (.[0].value // "")
          else error("expected 1 node with identifier \($id), found \(length)")
          end'
}

BEFORE=$(read_field) || { echo "baseline read failed" >&2; exit 1; }
case "$BEFORE" in *"$MARK"*)
  echo "field already holds $MARK; pick another marker" >&2; exit 1 ;;
esac

deviceterm tap --identifier "$FIELD" --pane "$DT_PANE"   # focus it

# Barrier, not politeness. The tap's receipt says the gesture was accepted for
# delivery, not that the guest processed it, and on a physical device touch and
# keyboard travel separate asynchronous pumps -- so `text` can overtake the tap
# and land wherever focus was before. Settling here is the only place that can
# be prevented; the value check below cannot recover keystrokes sent elsewhere.
deviceterm wait surface quiescent --pane "$DT_PANE"

deviceterm text "$MARK" --pane "$DT_PANE"

# Block on the value carrying the marker rather than reading straight back:
# `text` returns on dispatch, so an immediate read can precede the keystrokes
# landing. `--match contains` is needed because a tap puts the caret mid-string,
# so the value is not equal to the marker -- and it applies to the identifier
# too, which is why read_field's exactly-one check below still does the work of
# pinning this to one node.
deviceterm wait ax --identifier "$FIELD" --value "$MARK" --match contains \
  --pane "$DT_PANE" || { echo "marker never landed in $FIELD" >&2; exit 1; }

AFTER=$(read_field) || { echo "read-back failed" >&2; exit 1; }
case "$AFTER" in
  *"$MARK"*) echo "typed: before=[$BEFORE] after=[$AFTER]" ;;
  *)         echo "marker did not land: [$AFTER]" >&2; exit 1 ;;
esac
```

**Type a marker you first proved absent, and assert the whole marker arrived.**
"Contains `hello` and differs from the baseline" is not enough: a field that
already held `hello` passes that test when only `he` lands, so a partial
delivery reads as success. Proving the marker absent beforehand is what makes
its presence afterwards mean something.

**Do not assert `AFTER` equals `BEFORE` with the marker appended.** A tap places
the caret where you tapped, so text lands mid-string on a field that was not
empty. If you want an exact assertion, clear the field first (`0x33` is
`kVK_Delete`, one character per press) and then assert `AFTER == "$MARK"`.

`read_field` aborts rather than returning a sentinel when the identifier is
missing or matches more than once. A sentinel would have to be checked by every
caller, and an unchecked one silently becomes the "value" you compare.

**A failure here is ambiguous, and no read-back on this surface resolves it.**
An AX node carries `role`, `label`, `identifier`, `frame`, and `value` when the
element has one. **There is no focus property**, so an unchanged `value` cannot
tell you whether the tap failed to focus the field or the keystrokes never
arrived. Report it as "typing did not land" rather than naming a cause, and
narrow it by re-tapping and retrying before you conclude anything.

**`key`** takes a kVK virtual key code and sends a discrete event, so pair every
`down` with an `up`. **Verify it with a key that changes text**, not one that
moves focus:

```sh
# Start from an empty field, so the value you expect afterwards is exact.
# `0x33` is kVK_Delete, one character per press.
BEFORE=$(read_field) || { echo "baseline read failed" >&2; exit 1; }
[ -z "$BEFORE" ] || { echo "clear $FIELD first (0x33 is kVK_Delete)" >&2; exit 1; }

deviceterm key 0x00 down --pane "$DT_PANE"; deviceterm key 0x00 up --pane "$DT_PANE"

deviceterm wait ax --identifier "$FIELD" --value a --match exact \
  --pane "$DT_PANE" || { echo "'a' never landed in $FIELD" >&2; exit 1; }
```

`0x00` is `kVK_ANSI_A`, so a focused field's `value` gains an `a`.

**Use `--match exact` here, and empty the field to make that possible.** The
`text` scenario needs `contains` because a tap puts the caret mid-string, and it
pays for that twice over: `contains` folds case, so an `A` satisfies `--value a`,
and it widens the *identifier* too, so a neighbouring node whose identifier
merely contains `$FIELD` can satisfy the wait — returning before your field has
the key, which then makes an exact read-back afterwards report a failure that
has not happened yet. Emptying the field first removes the reason for `contains`
and both problems with it: an exact identifier cannot widen, and an exact value
cannot fold.

**If this times out while the field visibly gained a character**, read it with
`read_field` before concluding anything. A field that autocapitalises holds `A`,
which `--match exact --value a` will never match — that is the field's own
behaviour rather than a lost keystroke, and it is why the case question is
settled here by emptiness rather than by a looser comparison.

Block on the value rather than reading straight back, for the reason the `text`
block above gives: the key receipts report dispatch, not that the guest consumed
them. The same focus barrier applies too — these keys go wherever focus already
is, so establish it and settle before sending them.

**Do not use `0x30` here**: it is Tab, which moves focus and leaves `value`
untouched, so a read-back can neither confirm nor refute delivery. It appears in
`deviceterm help key` as a parsing example, not as a verifiable one.

`text` maps each character to a keypress and surfaces an unsupported character
as an error naming the offending character rather than silently dropping it, so
a nonzero exit tells you which character to split on.

### 5. A refused gesture

Worth running once to confirm refusals surface, and worth knowing that **it takes
three commands, not two.**

A contact gesture arriving while another holds a contact **queues** rather than
being refused. Measured: a tap issued 0.348s into a 3s hold blocked for 2.754s
and then ran. So a close racing only the *holder* refuses nothing, because a
holding composite is deliberately left to finish. You need a third command
already queued when the close lands, which `ContactLane.close()` cancels:

**`pane close` needs the shortId, not the UDID**, for the reason in *Invocation
conventions*. Resolve it with the guarded lookup there, or the close targets
whatever pane is current and the queued tap runs normally, which looks exactly
like the refusal path not working.

**Capture each background pid.** The `wait` below is the **shell builtin**, on
job pids; it is not `deviceterm wait`, and the sleeps around it are the timing
this scenario is built on rather than readiness polls, so neither is a candidate
for a condition wait. A bare `wait` returns 0 no matter how the jobs exited, and
putting it after the close on the same line overwrites the close's own status,
so the script would have no way to check either thing it depends on:

```sh
deviceterm long-press 0.5 0.5 --duration 5000 --pane "$DT_PANE" & hold=$!
sleep 0.3
deviceterm tap 0.4 0.4 --pane "$DT_PANE" > $DT_DIR/queued.txt 2>&1 & queued=$!
sleep 0.3
deviceterm pane close --mode detach --pane "$DT_REF"; close_rc=$?

wait "$queued"; queued_rc=$?
wait "$hold";   hold_rc=$?
echo "close=$close_rc queued=$queued_rc hold=$hold_rc"; cat $DT_DIR/queued.txt
```

Read it in this order:

1. **`close_rc` must be 0.** A close that failed to resolve makes everything
   below meaningless, and it is the failure this scenario is most likely to hit.
2. **`queued_rc` must be 1**, with `$DT_DIR/queued.txt` carrying `input lane
   refused the gesture; nothing was sent, retry`.
3. `hold_rc` is informational. The holder is deliberately left to finish, so it
   is not the one being refused.

**This scenario requires a simulator pane**, because it is built on `pane
close`, which cannot resolve a physical-device pane at all. On a device pane the
close fails with `intent.notFound` and the queued tap runs normally, which reads
as the refusal path not working.

**It closes the pane**, so run it last, or on a pane you are finished with.

### 6. Sweep as the tree fallback

On watchOS, `ax tree` returns empty `children` with a `note` and a `noteCode` of
`ax.watchOSEnumerationUnsupported`, by design, because the bridge's
`accessibilityChildren` walk is empty on that family. The note names `ax sweep`
as the workaround. Sweep, then run scenario 1's read-back against what the sweep
found.

`wait ax --source sweep` is the same fallback with the waiting built in, but
**it cannot report the unsupported walk that sent you here.** The watchOS note
rides on the `ax tree` response; a sweep's synthetic root carries only its own
truncation notes. So `wait ax` at its default tree source is what refuses fast
with `wait.unsupported`, while the same query under `--source sweep` has nothing
to refuse on.

How such a wait ends then depends on the probes, not on the device. Each sweep
is granted the smaller of the budget you asked for and the time left before the
overall deadline, so the budget shrinks as the wait runs on. A probe that
completes its grid and matches nothing leaves the wait pending, and if that
holds to the end you get `wait.timeout`. A late probe squeezed below what the
grid costs **truncates instead, and truncation is terminal**, so the same query
can just as well end early on `wait.inconclusive`. Neither ending says anything
about the device: size the timeout for a grid walk when you switch sources, and
read the code rather than assuming which one you got.

**A match still wins here**, which is the part worth not getting wrong: a
presence wait against a watch pane is satisfied by an element the tree can
return even though the walk that would enumerate its children is unsupported.
The refusal follows the observation, not the device family, so do not read
"watchOS" as "this wait always refuses".

An empty `children` with `truncated: false` means the bridge answered and found
no unique elements. A systemic bridge failure exits nonzero instead, so the two
are distinguishable.

**A web view is the other case this section serves**, and it is the reason not
to read a populated tree as a complete one. `ax tree` returns the browser's own
chrome and nothing from the page; `ax sweep` reaches the content. When the
daemon can prove the omission it says so, and a `wait ax` that ends on such an
observation reports it rather than a bare deadline. See *An AX wait reports what
it could not see*.

## Known broken, and sharp edges

Do not spend a run rediscovering these.

- **A sim pane can reach `failed` without a boot ever failing.** Sustained
  surface-pool exhaustion fails the pane after one controlled recovery attempt,
  so `wait pane failed` is reachable for a rendering reason rather than a
  lifecycle one. Re-attaching recovers it.
- **A sim attach can now fail fast, and retryably.** `pane.create` answers
  either that CoreSimulator did not respond in time or that too many simulator
  acquisitions are in flight, both as `rpc.serverError`. Retry rather than
  treating either as terminal: they exist so a stalled bridge refuses one caller
  instead of wedging the daemon for every caller.
- **A third concurrent rotation on one pane is refused, not queued.** The daemon
  admits two outstanding requests per pane; a third fails immediately as
  `rotate.unconfirmed` with a `details.reason` of `"queueFull"`, without
  dispatching. Confirmation itself waits up to 4 s for the observation and the
  CLI allows 18 s for the reply, so size a timeout above that rather than
  guessing.
- **`portrait-upside-down` is unreachable on a simulator.** See scenario 2.
- **`pinch` fails on physical devices** even though `capabilities.touch` reports
  true, because the real-device backend throws
  `unsupported(verb: "two-finger input")` unconditionally. The capability flag
  gates the family, not that verb.
- **`pane rename` and `pane move` return `intent.internalError`.** Both verbs
  parse, dispatch, and reach a handler that throws "not implemented"; neither
  mutates anything.
- **No CLI verb closes a physical-device pane.** `pane close` resolves against
  `simPanes` only, so a device pane is `intent.notFound` however you name it.
  Close it from the GUI, and budget for that when a device scenario needs a
  clean pane.
- **`crown --velocity` is accepted and silently ignored**, because the
  SimulatorKit crown builder takes only a delta. The streaming `--duration` path
  also no-ops below the watchOS recognizer's coalescing floor; use the
  single-shot `deviceterm crown N` for fine placement.
- **A CLI request cannot be cancelled.** Ctrl-C or a client timeout leaves the
  daemon's work running to completion, so a long sweep keeps holding the pane's
  accessibility queue after you have given up on it. Wait it out rather than
  reissuing into the queue behind it.
- **`doctor` reports `ok: true` during a GUI stall**, listing `tab.*` methods in
  `allowedMethods` that cannot currently answer. It is not a liveness probe for
  the GUI.
- **`inputSuperseded` was never exercised, and no route in this playbook's scope
  is known to produce it.** It comes from the daemon's `transferOwnership`,
  which runs when a live pane is *adopted* by a new owner session. Two routes
  that look like they would reach it do not: a **cross-tab pane drag is
  rejected** by the destination decoder, and the **shim's contextual relink**
  dispatches a detach followed by an attach, so the old pane is closed before
  the replacement mounts rather than having its ownership transferred. Treat its
  absence from a run as "not exercised", never as coverage, and report it if you
  ever see one.
- **There is no `location` verb by design**, and its absence is a stated product
  decision rather than an oversight. `capabilities.location` reports backend
  support for the GUI's Device > Location menu.

## Reporting

For each scenario, report the mutation you made, the read-back you asserted on,
and whether they agreed. When a receipt says `ok` and the read-back disagrees,
that is the finding: quote both rather than reconciling them by picking the one
you expected.

Report a check you could not provoke as not reproduced. That is a result. A
fabricated pass is not.

If a JSON key, error string, or coordinate convention here no longer matches
what you observe, report the drift so this playbook can be corrected. Nothing
automated checks its contents.
