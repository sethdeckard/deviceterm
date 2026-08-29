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
  answer input or accessibility reads. Check the pane you actually mean:

  ```sh
  DT_PANE=ee15455f-838b-4721-9794-dc51c29b6d8e
  deviceterm panes list --json | jq -r --arg u "$DT_PANE" '
    .[] | select((.udid | ascii_downcase) == ($u | ascii_downcase)) | .state'
  ```

  Anything but `rendering` means stop and wait, not proceed and interpret the
  failures.
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

Exit 1. So a successful receipt no longer hides a send that never happened. It
still does not mean the screen changed.

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

Exit 1. Rows are `<ref>\t<type>\t<key>`, where type is `sim` or `device` and the
key is a sim UDID or a physical `deviceId`. They are **sorted by paneId**, which
is a UUID you never see in the listing, so the order is arbitrary as far as you
are concerned. Treat it as a lookup aid, never as an ordering.

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
| `tap` | `x`, `y` | |
| `app-switcher` | `x`, `y` (the gesture's fixed start point, not yours) | |
| `long-press` | `x`, `y` | `durationMs` |
| `pinch` | | `durationMs` |
| `swipe` | | `dispatched`, `steps`, `durationMs` |
| `button` | `button` | |
| `key` | `keyCode`, `down` | |
| `text` | `bytes` | |
| `crown` | `delta` | `velocity`, `durationMs` |
| `rotate` | | exactly one of `orientation`, `direction` |

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

## The coordinate contract

**Every coordinate-bearing verb takes normalized coordinates in displayed
space.** `(0,0)` is the top-left of what you see in the pane, whatever the
orientation. The daemon rotates into the device's native surface on your behalf,
for input and for accessibility queries alike.

**So compensate for nothing.** No transposition, no manual rotation, no
per-orientation special case in your script. Portrait is the identity transform,
which is exactly why a portrait-only run proves nothing about this: read the
next section before concluding a landscape check passed.

**Node frames are in that same displayed space, but they are not normalized.**
Divide a frame's centre by the root frame's `w` and `h` before feeding it back
to `ax point` or `tap`.

### A worked example, in two orientations

The Maps *Map Modes* button on an iPhone 17, read and tapped in each
orientation:

| | root frame | node frame | normalized centre |
|---|---|---|---|
| `landscape-right` | 874 x 402 | x 764, y 26, w 48, h 48 | `0.901601 0.124378` |
| `portrait` | 402 x 874 | x 338, y 382, w 48, h 48 | `0.900497 0.464530` |

The arithmetic, landscape-right:

```
centre     x = 764 + 48/2 = 788      y = 26 + 48/2 = 50
normalized x = 788 / 874 = 0.901601  y = 50 / 402 = 0.124378
```

Both resolved through `ax point` and both tapped the button, untransformed.

**What this pair shows is that the recipe works untransformed in both
orientations.** That is the claim worth making, and both taps landed.

**What it does not show is anything about the rotation transform**, and the
numbers are a trap if you read them that way. The centre moves from (362, 406)
to (788, 50) in raw points, which is not the rigid rotation of a fixed control:
Maps relaid its own interface. Two effects are stacked here, the changed root
and the app's reflow, and you cannot separate them from these numbers alone.

The operational rule is the same either way. **Re-read the tree after every
rotation**, and divide by the root you just read. A coordinate cached from
another orientation is stale, whether it went stale because the root swapped or
because the app moved the control.

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

**`ax sweep`'s root frame is a placeholder** (`0,0,1,1`), not the screen's. Take
your scale from an `ax tree` root, never from a sweep root.

## Reading a coordinate out of the tree

```sh
deviceterm ax tree --pane "$DT_PANE" > $DT_DIR/tree.json
jq -r '
  .tree.frame as $r
  | [ .tree | recurse(.children[]?) ]
  | .[1:]
  | map(select((.frame.w // 0) > 0 and (.frame.h // 0) > 0))
  | map({ role, label, identifier,
          x: ((.frame.x + .frame.w/2) / $r.w),
          y: ((.frame.y + .frame.h/2) / $r.h) })
  | map(select(.x >= 0 and .x <= 1 and .y >= 0 and .y <= 1))
  | .[]
  | [ .x, .y, (.role // ""), (.label // ""), (.identifier // "") ]
  | @tsv
' $DT_DIR/tree.json
```

**The bounds check is on the computed centre, not on the frame**, because that
is the precondition the coordinate actually has to meet before you can feed it
to `tap`. Guarding the frame's origin and size instead lets through a node that
starts inside the root and extends past it.

It is not decoration either. Maps' dismiss-popup group carries a frame of
`x -402, y -874, w 1206, h 2622`: negative origin, roughly three times the root
in both axes. A selector filtering on `w > 0` alone picks it up first, and its
normalized centre is meaningless. Filter on `role` as well when a screen has
several such wrappers.

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
  | jq '.tree | {step, budgetMs, sweepedPoints, truncated, note}'
```

`truncated: true` means part of the grid went unqueried and `sweepedPoints`
counts what it reached. **An element missing from a truncated sweep is not
evidence it is off screen.** A truncated sweep also carries a `note` naming what
to try; a completed one carries none.

Two things that surprise people:

- **A sweep can truncate for reasons that have nothing to do with your step.**
  The budget covers the wait for the pane's serial accessibility queue, and that
  wait is charged from when your request arrived, not from when it reached the
  front. A sweep queued behind a long one can come back `sweepedPoints: 0` with
  its whole budget already spent. Retry when the pane is quieter.
- **At the ceiling the advice changes.** A sweep that truncates at
  `budgetMs: 60000` gets a different note, one that never suggests `--budget`,
  because there is no larger budget to ask for. Coarsen `--step` or retry.

## Scenario library

Each scenario: **mutate -> read back -> assert the state changed**. Record a
baseline before you mutate; every assertion below is a delta.

### 1. Round-trip a control (the flagship)

The one that matters, because it is the whole contract in five commands, and
because a false pass here looks exactly like a real one.

```sh
deviceterm ax tree --pane "$DT_PANE" > $DT_DIR/before.json
jq '.tree.frame' $DT_DIR/before.json                      # the root you divide by
```

Choose a control from the recipe above, compute its normalized centre, then:

```sh
deviceterm ax point 0.901601 0.124378 --pane "$DT_PANE" | jq '.element'
deviceterm tap 0.901601 0.124378 --pane "$DT_PANE" --json
deviceterm ax tree --pane "$DT_PANE" > $DT_DIR/after.json
```

Assert three things, in order:

1. **`ax point` returns the element you took the coordinate from.** Compare
   `role` and `label`, and `identifier` when the node carries one. A different
   element means your arithmetic or your root is wrong. `null` means check you
   read `.element` and not `.tree`.
2. **The tap receipt is `ok`** with the coordinates echoed back.
3. **The label set changed.** Diff the labels in `$DT_DIR/before.json` against
   `$DT_DIR/after.json`. This is the assertion; the other two are its supports.

A real run of this looked like: `Card controller, Dictate, Locations, Map, Map
Modes, Maps, Tracking, profile` becoming `Close, Driving, Explore, Labels, Map,
Map Modes, Maps, Satellite, Traffic, Transit`. Step 3 passing while step 1 fails
means you tapped something, just not what you meant to.

### 2. Orientation coverage

**Portrait alone proves nothing**, because it is the identity transform for
every rotation in the system. A run that only covers portrait cannot distinguish
a correct implementation from one that rotates nothing at all.

Run scenario 1 in each of:

```sh
deviceterm rotate portrait --pane "$DT_PANE"
deviceterm rotate landscape-left --pane "$DT_PANE"
deviceterm rotate landscape-right --pane "$DT_PANE"
```

Re-read the tree after each rotation. The root frame's `w` and `h` swap, and
every normalized coordinate moves with them.

**Do not schedule `portrait-upside-down` on a simulator.** The command returns
`ok` and exits 0, the device orientation moves, and the **display refuses**: the
framebuffer keeps portrait dimensions and the accessibility tree is identical to
portrait. Verified on iPhone 17 and iPad mini, in Maps and on SpringBoard, via
the direct set and via two `rotate left` steps. `Sources/CoreSimulatorBridge/as-tested.md`
records the same split, and its `uiOrientation` table has rows only for portrait,
landscapeLeft, and landscapeRight. Reaching it needs physical hardware.

**`rotate left` and `rotate right` are relative**, and they resolve against an
orientation only DeviceTerm tracks. An app that forces its own orientation
leaves that base stale, so prefer the absolute forms in a scripted run.

### 3. App Switcher

```sh
deviceterm app-switcher --pane "$DT_PANE" --json
deviceterm ax tree --pane "$DT_PANE" | jq -r '[.tree | recurse(.children[]?)] | map(.label // empty) | .[]'
```

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
deviceterm ax tree --pane "$DT_PANE" \
  | jq -r '[.tree | recurse(.children[]?)] | map(.label // empty) | .[]'
```

Assert the app's controls are **gone**, not that anything specific appeared:
SpringBoard's own labels vary by OS version and Home Screen contents, while the
disappearance of the label set you recorded before pressing is unambiguous.

**`text` needs focus, and the coordinate you tapped is not a durable handle on
the field.** Focusing it raises the keyboard, which reflows the layout, so the
same `<x> <y>` may point at something else by the time you read back. Re-resolve
the node by `identifier` from a fresh tree instead, and pick a field that
carries one:

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

deviceterm tap <x> <y> --pane "$DT_PANE"          # focus it
deviceterm text "$MARK" --pane "$DT_PANE"

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
deviceterm key 0x00 down --pane "$DT_PANE"; deviceterm key 0x00 up --pane "$DT_PANE"
```

`0x00` is `kVK_ANSI_A`, so a focused field's `value` gains an `a` and the same
baseline diff applies. **Do not use `0x30` here**: it is Tab, which moves focus
and leaves `value` untouched, so a read-back can neither confirm nor refute
delivery. It appears in `deviceterm help key` as a parsing example, not as a
verifiable one.

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

**Capture each background pid.** A bare `wait` returns 0 no matter how the jobs
exited, and putting it after the close on the same line overwrites the close's
own status, so the script would have no way to check either thing it depends on:

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

On watchOS, `ax tree` returns `{children: [], note: "..."}` by design, because
the bridge's `accessibilityChildren` walk is empty on that family. The note names
`ax sweep` as the workaround. Sweep, then run scenario 1's read-back against
what the sweep found.

An empty `children` with `truncated: false` means the bridge answered and found
no unique elements. A systemic bridge failure exits nonzero instead, so the two
are distinguishable.

## Known broken, and sharp edges

Do not spend a run rediscovering these.

- **`presentationOrientation` lags the screen it describes.** `rotate` returns,
  for a pane observing display orientation, without waiting for the observation
  to land. So `deviceterm rotate landscape-left && deviceterm ax point ...` can
  straddle the window and map through the *previous* screen. Input maps through
  the identical property, so a read-back inside that window can confirm an
  element the tap never hit. Poll for the root frame to swap before asserting.
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
