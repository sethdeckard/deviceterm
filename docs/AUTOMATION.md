# Automating DeviceTerm

Use the `deviceterm` CLI to control DeviceTerm itself: open and arrange tabs,
panes, and windows, inspect workspace state, drive terminal panes from an
automation tab, wait for device state, and consume events. The caller can be a
person at a prompt, a script, an agent, or a program coordinating several
agents; the commands and rules are the same.

Run these commands from a shell inside a DeviceTerm tab. The terminal pane
provides the session identity that authorizes them.

Driving the device inside a pane, including touch, keys, buttons, and
accessibility, is covered in [`USAGE.md`](USAGE.md). The JSON shapes, exit
codes, and stability promises behind every command here are defined in
[`INTEGRATION.md`](INTEGRATION.md).

Skills that teach a coding agent to use these commands live in
[`deviceterm-skills`](https://github.com/sethdeckard/deviceterm-skills), a
separate repository.

## Contents

- [Understand Tabs, Sessions, and Authority](#understand-tabs-sessions-and-authority)
- [Control the Workspace](#control-the-workspace)
- [Discover State](#discover-state)
- [Drive Other Tabs](#drive-other-tabs)
- [Wait for Device State](#wait-for-device-state)

## Understand Tabs, Sessions, and Authority

Authority has three levels.

An **ordinary tab** reads its caller-visible workspace and performs mutations
contained to workspace objects it owns. A terminal session can rename or split
its own tab, close that tab when it is the sole terminal, close or rename its
own terminal pane, and operate on Simulator and physical-device panes in its
tab.

Terminal panes remain separate trust units. Owning one terminal in a split tab
does not allow a caller to close or rename a sibling terminal pane.

One exception belongs to the shim rather than to you. Running `devicectl
install` or `launch` in a tab moves that device's mirror to it, out of whichever
unprotected tab was showing it, on the reasoning that the device context
followed your command. `deviceterm device attach` refuses the same move and
tells you to drag the pane across instead.

Opening an **automation tab** causes the GUI to issue that tab a live grant.
Its role stays descriptive if the grant is missing or revoked, so the tab keeps
its name and badge while holding no automation authority.

Eight commands always require the grant because they create or rearrange
workspace surfaces, change global focus, or drive a terminal:

- `tab open`
- `tab focus`
- `tab move`
- `window open`
- `window focus`
- `pane focus`
- `pane send-input`
- `pane capture-text`

The grant also satisfies target-level ownership checks for commands such as
`tab close`, `window close`, `tab rename`, `tab protect`, `tab unprotect`,
`pane split`, `pane close`, and `pane rename`.

A **protected tab** is invisible to sessions outside it, and a grant does not
make it visible. Opt a tab out of cross-session discovery and control with
[`tab protect`](#protect-a-tab).

Creating and arranging surfaces is gated even when the target is your own tab,
because the effect is not contained to it. Reordering can shift other tabs,
and focusing one can replace the visible tab and pane focus in that window.

The consequence is that an ordinary script cannot open new tabs or windows for
itself. It can still split its own tab with `pane split`; anything that mints a
tab or window needs a person to open the first automation tab.

### Know Your Session

DeviceTerm injects a session identity into every terminal pane's shell:
`DEVICETERM_SESSION` holds the session id, `DEVICETERM_SESSION_CAP` holds the
session credential, and companion variables locate the daemon socket and the
per-session shim directory. The CLI reads them transparently; no command takes
a credential flag or operand.

A terminal split is its own session. The GUI treats the tab as one workspace,
but each terminal pane carries a separate CLI identity with its own credential.
The terminal pane's public pane id is that session id.

Device panes are scoped to the tab. Every terminal session in a tab drives the
tab's Simulator and physical-device panes, whichever terminal booted or
attached the device. Sharing a tab is the consent gesture. A device pane in
another tab is refused with the same error as an unknown pane.

Closing one terminal of a split tab hands its device panes to the surviving
terminals instead of orphaning them.

A newly created terminal can have a session id before its shell surface is
attached. An open or split receipt therefore makes the terminal addressable,
but does not assert that input is ready. A request racing surface attachment
can fail and should be retried after the terminal becomes usable.

The session's role is readable without a daemon round-trip:

```sh
echo "$DEVICETERM_SESSION_ROLE"
```

### Trust the Terminal, Not the Token

The capability in `DEVICETERM_SESSION_CAP` is one authentication factor, not
proof of origin. It is inherited environment, readable by any process running
under your uid, so possession alone establishes nothing. On every scoped
request the daemon also checks the caller's kernel provenance: its POSIX
session, controlling terminal, and session-leader start time, or those of a
live ancestor, must match the terminal the session is bound to.

What earns trust is reaching the session's terminal, either by running in it
or by descending from something that does. Child processes normally inherit
the tab's terminal and may control the session, which is why the cap is
deliberately visible to them. Do not strip it from a subprocess environment.

A detached child, such as a process started with `setsid`, remains authorized
only while its live parent chain reaches the tab. This lets an agent harness
drive the session it is running inside. Orphan it so no live ancestor is left
in the terminal, and it is refused. A process elsewhere that copied the cap is
also refused because it has no ancestor in the tab.

### Escalate Only Through the GUI

Cross-tab terminal input and capture require a live automation grant, and only
the GUI issues one when a person opens an automation tab. There is no CLI verb
for escalation, and constructing the raw request by hand does not work. The
daemon refuses grant creation from anything but the validated GUI.

A role string such as `"automation"` is descriptive metadata. Without a live
grant, an automation-scoped command fails with
`intent.automationRequired` even when `DEVICETERM_SESSION_ROLE` still says
`automation`.

[Open an Automation Tab](#open-an-automation-tab) covers the grant lifecycle.

## Control the Workspace

### Open Tabs, Panes, and Windows

Create workspace surfaces from a script or agent:

```sh
deviceterm tab open --cwd "$PWD" --command 'make test'
deviceterm pane split --direction right
deviceterm window open
```

`tab open` creates a tab with an initial terminal pane. `pane split` creates a
terminal beside an existing pane in the caller's tab. `window open` creates a
window containing a tab and its initial terminal. `--command` is typed into the
new tab's login shell after it attaches, so the command runs once and the shell
stays interactive.

`tab open` and `window open` need a live automation grant. `pane split` does
not need one when it targets a tab the caller owns. Splitting another visible
tab requires a grant.

Open and split mutations wait for terminal session creation:

- `window open` returns the committed window, first tab, and initial terminal
  pane.
- `tab open` returns the host window, new tab, and initial terminal pane.
- `pane split` returns the host tab and new terminal pane.

The pane's id is therefore available to the next command without polling.
These receipts wait for the session id, not for shell or surface readiness.

A tab can commit before creation of its initial terminal fails. The command
then fails with `intent.mutationFailed` while retaining the tab on screen.
In JSON mode, `error.details.committed.tab` contains the committed tab,
including its id and failed state. Keep that id if the script needs to inspect,
rename, or close the retained tab.

Receipt shapes are defined in
[workspace receipts](INTEGRATION.md#workspace-receipts).

### Arrange, Select, and Close Surfaces

Reorder, retitle, focus, and close surfaces by reference:

```sh
deviceterm tab move abc123 --window def456 --index 0
deviceterm tab rename "auth-feature"
deviceterm tab focus abc123
deviceterm window focus f0a123
deviceterm tab close --mode shutdown
deviceterm pane close sim123 --mode detach
```

`tab move` moves a tab to the named window. It appends unless `--index`
supplies a zero-based destination index. Moving within the same window requires
`--index`.

`tab close` and `window close` take `--mode <detach|shutdown>` to decide what
happens to linked Simulators, the same decision the GUI close prompt offers.
The CLI never prompts.

`tab focus`, `tab move`, and `window focus` need a live automation grant,
including when the target is the caller's own tab or window.

`tab rename` needs a grant only when the caller does not own a terminal in the
target tab.

`tab close` has a stronger ownership rule. Without a grant, it reaches only a
tab whose sole terminal is the caller. Closing a split tab would end the other
terminal sessions, so it requires a grant.

`window close` applies the same sole-terminal rule to every tab it contains.
It refuses a window holding a tab the caller cannot see, so it cannot tear down
a co-hosted protected tab.

`pane close` and `pane rename` work for terminal, Simulator, and
physical-device panes. Their authority depends on pane kind:

- A terminal pane requires that exact pane's session or a live automation
  grant. Owning a sibling terminal in the same tab is not enough.
- A Simulator or physical-device pane requires ownership of a terminal in its
  tab or a live automation grant. The daemon retains its cohort authorization
  check for the pane-targeted request.

Closing the last terminal pane would implicitly close its tab, so
`pane close` refuses with `intent.wouldCloseTab`. Use `tab close` when closing
the workspace is intended.

An explicit `pane close --mode <detach|shutdown>` is valid only for a
Simulator. Supplying `--mode` for a terminal or physical-device pane fails
with `intent.unsupportedPane` after the pane reference resolves. Omitting
`--mode` closes those pane kinds normally and uses `detach` for a Simulator.

Both rename commands accept at most two positional arguments:

```sh
deviceterm tab rename "auth feature"
deviceterm tab rename abc123 "auth feature"
deviceterm pane rename "build shell"
deviceterm pane rename term123 "build shell"
```

One positional argument names the current tab or pane. Two use the first as
the target and the second as the name. Quote a multi-word name so it remains
one argument. More than two positionals is a usage error.

Pass a quoted empty name to clear it:

```sh
deviceterm tab rename ''
deviceterm pane rename term123 ''
```

A name beginning with `-` must follow `--` so it is not parsed as an option.

## Discover State

### List Tabs, Panes, Windows, and Devices

The public workspace hierarchy is window, tab, pane:

```sh
deviceterm window list
deviceterm tab list
deviceterm pane list
deviceterm devices list
```

`window list` returns the caller's window. Add `--all` for every
caller-visible window.

`tab list` returns one row per GUI tab in the caller's window. Add `--all` to
span every caller-visible window, or use `--window <ref>` to select one
window. A split tab is still one tab row.

`pane list` returns every terminal, Simulator, and physical-device leaf in the
target tab's layout order. It defaults to the caller's tab; use
`--tab <ref>` for another caller-visible tab.

`devices list` reports DeviceTerm-owned booted Simulators and connected physical
devices. It is the device roster, not the GUI pane layout. An externally
booted Simulator stays absent until it is attached; see
[device roster rows](INTEGRATION.md#device-roster-rows).

An empty list with exit 0 is a successful empty visibility projection.
Failures exit nonzero and emit a JSON error envelope.

Pass `--json` to any list for the machine-readable shapes defined in
[Discovery and State](INTEGRATION.md#discovery-and-state).

Inspect an individual object with `show`:

```sh
deviceterm window show
deviceterm tab show
deviceterm pane show
```

`window show` returns `{window, tabs}`. `tab show` returns
`{tab, panes, layout}`. Its pane array contains every pane kind in layout order,
and `layout` is the recursive public split tree. `pane show` returns one
`WorkspacePane` with kind-specific terminal, Simulator, or physical-device
details.

The public projection comes from live GUI state. It is not reconstructed from
daemon session rows. A tab whose initial terminal creation failed remains
visible with `state` set to `failed`, an empty pane list, and no live layout.

### Read Terminal Working Directories

Run this from an automation tab to read the live working directory of a
terminal pane:

```sh
deviceterm pane show "$PANE" --json | jq -er '.terminal.cwd'
```

`pane list --json` and `tab show --json` include the same field in each
terminal row. Every command takes a fresh process snapshot, so the value
follows `cd`, nested interactive shells, and the return to an outer shell.

The field requires a live automation grant, even when the caller owns the
terminal. An ordinary tab receives a successful workspace response with `cwd`
omitted.

A process handoff can make one read inconclusive. If the next step depends on
the directory, let the foreground command settle and re-read with a bounded
deadline. Do not fall back to a startup `--cwd` value, since it may be stale.

### Resolve Workspace References

The CLI sends raw references to the GUI. Resolution is case-insensitive and
uses ordered tiers.

Window and tab references resolve as:

1. exact short id;
2. exact full UUID;
3. exact unique name;
4. unique full-UUID prefix.

Pane references resolve as:

1. exact short id;
2. exact full pane id;
3. exact unique name;
4. exact Simulator UDID or physical-device id;
5. unique full-pane-id prefix.

Names match exactly, never by prefix. A name matching more than one visible
object is ambiguous.

Window and tab short ids are the first six lowercase hexadecimal characters
of their UUIDs. Pane short ids are six lowercase Crockford base32 characters.
A terminal pane's full pane id is its session id.

The one-based `index` printed for a window is display metadata. It is never a
window reference. A numeric-looking window short id remains unambiguous because
window indices do not participate in resolution.

An omitted reference, or the literal `current`, is resolved from the calling
terminal session. It does not borrow whichever window, tab, or pane currently
has GUI focus. For an external caller:

- current window means the window containing its terminal;
- current tab means the tab containing its terminal;
- current pane means that terminal pane.

Focus and current are separate fields in the JSON projection. Focus describes
the GUI's present keyboard selection; current describes the calling session's
workspace identity.

### Check Health With doctor

```sh
deviceterm doctor
```

`doctor` checks the session environment, the `xcrun` shim, the daemon socket
and handshake, session authentication, linked device panes, and the methods
the daemon admits for this session. Use `--json` in a script and branch on the
exit status. The report shape and check names are defined in
[the doctor report](INTEGRATION.md#doctor-report).

### Diagnose Version Skew

After an upgrade, confirm the live daemon and the bundled CLI agree:

```sh
deviceterm version --json
```

Compare the `daemon` and `rpcWire` fields. A missing `daemon` field means the
version probe did not complete; it does not prove that no daemon is reachable.
Field semantics and a ready-made check are in
[the version report](INTEGRATION.md#version-report).

The public release version and internal wire version are different contracts.
The release version follows public CLI and JSON compatibility. The wire
version coordinates the bundled app, daemon, CLI, and shim during an update.

## Drive Other Tabs

### Open an Automation Tab

Open the tab with **Shell ▸ Open Automation Tab** or ⇧⌘T.

The GUI issues that tab's terminal session a live automation grant. The grant
lives in daemon memory and is checked on every request that needs it. It is
revoked when the tab closes, when the issuing GUI connection is lost, or when
the session ends.

The grant covers `tab open`, `tab focus`, `tab move`, `window open`,
`window focus`, `pane focus`, `pane send-input`, and `pane capture-text`.
An ordinary tab receives `intent.automationRequired` for those commands, and
the CLI cannot grant authority to itself.

The same grant satisfies ownership checks for visible targets. It does not
make a foreign protected tab visible.

### Send Input to Another Tab

Find the target tab and select a terminal pane from its live projection:

```sh
detail=$(deviceterm tab show auth-feature --json) || exit $?

TARGET_PANE=$(
  printf '%s\n' "$detail" |
    jq -er '
      [.panes[] | select(.kind == "terminal")] |
      if length == 1 then .[0].id
      else error("expected exactly one terminal pane")
      end
    '
)

deviceterm pane send-input "$TARGET_PANE" -- 'make test\n'
```

The tab name resolves only when it is an exact unique name. If the tab contains
several terminal panes, choose one by its id, short id, or unique pane name
instead of assuming a primary terminal.

`pane send-input` requires an explicit terminal pane reference and a live
automation grant. It does not accept a tab reference.

Instant input is dispatched before the command returns. With
`--type-delay <ms>`, typing is animated one character at a time and the
command returns as soon as typing is enqueued, so it may still be running.
Neither result confirms that the target shell executed anything.

The success receipt includes the committed terminal pane, the UTF-8 byte
count, and the optional effective delay. It never echoes the text. Receipt
fields and pacing limits are defined in
[send input](INTEGRATION.md#send-input).

### Capture Another Tab

Capture the selected terminal pane:

```sh
deviceterm pane capture-text "$TARGET_PANE"
```

The capture is that terminal pane's currently visible viewport; scrollback is
not included. Human output is the raw text, so a redirect saves the screen.
`--json` returns `{pane, text}`.

The command requires an explicit terminal pane reference and a live automation
grant. See [capture a viewport](INTEGRATION.md#capture-a-viewport).

### Protect a Tab

Protect the current tab when other sessions should not see or control it:

```sh
deviceterm tab protect
```

Every terminal session in the tab changes together. Other sessions cannot
list the protected tab or its panes, resolve its references, capture a terminal
inside it, or send input to it. Sessions inside the tab keep access.

Automation grants do not bypass protection. An automation tab cannot capture
or type into a foreign tab once that target is protected.

Protecting a tab does not lock its own sessions out. Unprotect it from inside:

```sh
deviceterm tab unprotect
```

Without a grant, both directions require the caller to own a terminal in the
target tab. A caller targeting a visible tab it does not own receives
`intent.automationRequired`.

A grant can protect a visible, unprotected foreign tab. Protection then hides
that tab from the automation caller, so the caller cannot resolve it to
unprotect it from outside. A foreign protected target fails as
`intent.notFound`, because grants never widen visibility.

Each command returns a workspace mutation receipt whose `tab.protected` value
is the committed state. A definite daemon refusal, indeterminate transition,
or superseding mutation is a command failure rather than an optimistic success
receipt. See [set protection](INTEGRATION.md#set-protection).

A protected tab's pill carries a lock in the tab strip, beside the wand if the
tab is also an automation tab. The lock reflects the tab's effective protected
state.

## Wait for Device State

### Use Wait for One-Shot Convergence

Commands that trigger device changes can return before the resulting state is
observable. Use `deviceterm wait` when the next action depends on that state:

```sh
xcrun simctl boot "$UDID"
deviceterm wait pane rendering --pane "$UDID" --timeout 30000
```

The default deadline is 30000 milliseconds. `--pane` accepts the same pane
references as input commands. An explicit pane reference may appear after the
wait starts. Once a pane resolves, the wait stays pinned to that pane and fails
if it disappears.

Wait for an accessibility element after launching an app or sending input:

```sh
xcrun simctl launch "$UDID" com.example.App
deviceterm wait ax --identifier login-button --role Button --pane "$UDID"
```

Match by exactly one of `--identifier` or `--label`. `--role` adds an exact
role match. `--match contains` matches a substring and folds case, for a label
carrying a count or an ellipsis.

`--value` adds a filter on the element's own value, compared under the same
`--match` mode. It narrows an element the selector already named rather than
selecting one itself.

Wait for something to go away with `--state absent`:

```sh
deviceterm wait ax --label "Saving..." --match contains --state absent
```

Human output reports `condition=ax.disappears` and `matches=0`. With `--json`
the receipt's condition is `ax.disappears` and `observation.matchCount` is 0.

DeviceTerm will not conclude absence from an observation that did not see
everything, because the element could be in the part that went unseen. A
truncated sweep reports `wait.inconclusive` at once, and an unsupported tree
walk reports `wait.unsupported`. An incomplete tree is retried, and reports
`wait.inconclusive` only if no complete observation arrives before the
deadline. An element still matching at the deadline is an ordinary
`wait.timeout`, because a sighting settles the question whatever else the
observation missed.

Tree observation is the default. On a family where the tree walk is
unavailable, use a sweep:

```sh
deviceterm wait ax --label Continue --source sweep \
  --step 0.05 --budget 20000 --pane "$UDID"
```

For a sweep wait, DeviceTerm reduces the requested or default sweep budget to
the milliseconds remaining before the overall wait deadline. A timed-out wait
does not leave a longer sweep occupying the pane's accessibility queue, except
for an already in-flight bridge call that cannot be interrupted.

Read the matched elements with `--json`. Human output reports only the match
count. The receipt lists up to 20 entries under `matches`, with `matchCount`
for the true total.

Presentational roles rank last, entries with no `normalizedCenter` rank next
to last, and smaller frames rank first, so `matches[0]` is the element you are
most likely able to operate.

The ordering is a heuristic. Do not pick from the list. Two commands act on a
match, and both make the same selection:

```sh
deviceterm wait ax --label Continue --match contains --print center
deviceterm tap --label Continue --match contains
```

`--print center` writes a bare `x y` and nothing else, ready to pass as a
coordinate verb's two positional arguments. `tap` with the same selector taps
that element directly, so no coordinate crosses the shell and the whole
locate-and-tap is one command with one argument list. A tool that approves
shell commands by matching a prefix can cover `deviceterm tap --label`; it
cannot cover a `$(...)` substitution wrapped around `--print center`.

Both refuse rather than guess. `wait.unreachable` means nothing eligible
matched, and `wait.ambiguous` means several unrelated elements did. Narrow
with `--role`, `--value`, or `--identifier`. A refusal sends no tap either way,
so a refused `tap` costs an exit code rather than an input you cannot take
back.

What a refusal writes differs. `--print center` writes nothing at all, so one
piped onward supplies no coordinate. `tap --json` writes the same error
envelope every other JSON failure writes, so test the exit code rather than
stdout emptiness.

`tap` accepts the whole selector, including `--source sweep` and its `--step`
and `--budget`. Its receipt reports the coordinate tapped, and the role when it
is a single word. `--json` adds `role`, `label`, `identifier`, `matchCount`,
and `elapsedMs`.

An observation that did not see everything is not proof the element is absent.
Where a plain `wait ax` has nothing else to report, it reports that observation
instead of a bare `wait.timeout`, with the daemon's note as the message and
`note` and `noteCode` in `details`.

The error code says which kind. `wait.inconclusive` means coverage fell short
of the screen. `wait.unsupported` means full coverage was unavailable in one
of two ways: a pane with no accessibility capability yields no observation at
all, while a family whose tree walk does not enumerate still returns its root
and carries a `noteCode`. That field tells them apart, and only the second is
helped by another `--source`.

Because the root survives the second case, a query the root itself matches
succeeds rather than reporting `wait.unsupported`.

Branch on `noteCode` for the remedy. `ax.watchOSEnumerationUnsupported` and
`ax.treeIncomplete` both send you to `--source sweep`.
`ax.sweepTruncated` means a larger `--budget` may help, and
`ax.sweepTruncatedAtMaxBudget` means it cannot, so widen `--step` or retry when
the pane is quieter.

Wait for an observed orientation and a stable rendered surface:

```sh
deviceterm wait orientation landscape-left --pane "$UDID"
```

Orientation waits require two consecutive observations with the requested
confirmed orientation and the same positive surface dimensions. This prevents
a transient or degenerate surface read from being accepted as settled.

Wait for the rendered surface to hold still:

```sh
deviceterm wait surface quiescent --settle 800 --pane "$UDID"
```

The condition is `surface.quiescent`, and the observation reports the
`surface` it settled on plus the `settleMs` it was given.

Use it after a change that leaves nothing specific to wait for. Quiescence is
the surface being unchanged rather than advanced by a known amount, because
the increment is backend-dependent. A pane with no surface is pending, not
quiescent. It is not a rotation signal, since dimensions do not swap on a
turn.

The three outcome classes are distinct:

- success: the condition was observed before the deadline;
- `wait.timeout`, exit 124: the overall wait deadline expired;
- another nonzero failure: the observation was unsupported, inconclusive, or
  its state query failed.

An individual RPC deadline remains `transport.timeout`. A malformed response,
connection failure, pane ambiguity, or other query failure returns immediately
under its shared error code and is neither retried nor remapped to
`wait.timeout`.

### Use Events as a Latency Signal

`deviceterm events` streams the current session's pane transitions and session
close, plus global Simulator boot and shutdown transitions, one JSON object per
line:

```sh
deviceterm events
```

The stream has no replay or durable journal. Events published before the
subscription is established are not delivered later, and a daemon restart
closes the stream.

Use `deviceterm wait` when correctness depends on reaching a final observable
condition. Use events for long-running observation or as a low-latency signal
to refresh current state. Event shapes, ordering, and loss behavior are
defined in [Events](INTEGRATION.md#events).

An external Simulator can emit boot and shutdown events while staying absent
from `devices list`; use `xcrun simctl` when you need its metadata.
