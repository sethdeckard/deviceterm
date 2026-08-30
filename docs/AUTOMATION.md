# Automating DeviceTerm

Use the `deviceterm` CLI to control DeviceTerm itself: open and arrange tabs,
panes, and windows, inspect workspace state, drive other tabs from an
automation tab, wait for device state, and consume events. The caller can be a
person at a prompt, a script, an agent, or a program coordinating several
agents; the commands and rules are the same.

Run these commands from a shell inside a DeviceTerm tab. The tab provides the
session identity that authorizes them.

Driving the device inside a pane (touch, keys, buttons, accessibility) is
covered in [`USAGE.md`](USAGE.md). The JSON shapes, exit codes, and stability
promises behind every command here are defined in
[`INTEGRATION.md`](INTEGRATION.md).

## Contents

- [Understand Tabs, Sessions, and Authority](#understand-tabs-sessions-and-authority)
- [Control the Workspace](#control-the-workspace)
- [Discover State](#discover-state)
- [Drive Other Tabs](#drive-other-tabs)
- [Wait for Device State](#wait-for-device-state)

## Understand Tabs, Sessions, and Authority

Authority has three levels.

An **ordinary tab** reads its caller-visible workspace and mutates only
itself: its own device panes, its own title, its own splits. It sees every
unprotected tab, which it needs in order to find its own things, and it can
touch none of them.

One exception, and it belongs to the shim rather than to you. Running
`devicectl install` or `launch` in a tab moves that device's mirror to it,
out of whichever unprotected tab was showing it, on the reasoning that the
device context followed your command. `deviceterm device attach` refuses
the same move and tells you to drag the pane across instead.

Opening an **automation tab** causes the GUI to issue that tab a live grant.
Its role stays descriptive if the grant is missing or revoked, so the tab keeps
its name and its badge while holding no authority.

The grant adds three groups: creating and arranging surfaces (`tab open`,
`tab select`, `tab move`, `window open`, `window focus`), reading or typing
into another tab (`tab capture`, `tab send-input`), and the workspace verbs
whose ownership requirement you don't meet (`tab close`, `window close`,
`tab rename`, `pane open --terminal`, `pane close`). That last group covers
a tab that isn't yours, and it covers closing one of your own that a second
terminal shares.

A **protected tab** is invisible to other sessions, and a grant does not
reach it. Opt a tab out of everything above with
[`tab set-protected`](#protect-a-tab).

Creating and arranging surfaces is gated even when the target is your own
tab, because the effect isn't contained to it: a reorder can shift other tabs,
and selecting one can replace the visible tab and pane focus in that
window.

The consequence is that a script can't open new tabs or windows for itself. An
ordinary tab can still split itself with `pane open --terminal`; anything that
mints a tab or a window needs a person to open the first automation tab.

### Know Your Session

DeviceTerm injects a session identity into every terminal pane's shell:
`DEVICETERM_SESSION` holds the session id, `DEVICETERM_SESSION_CAP` holds the
session credential, and companion variables locate the daemon socket and the
per-session shim directory. The CLI reads them transparently; no command
takes a credential flag or operand.

A terminal split is its own session. The GUI treats the tab as one workspace,
but each terminal pane carries a separate CLI identity with its own
credential.

Device panes are scoped to the tab. Every terminal session in a tab drives
and lists the tab's device panes, whichever of them booted or attached the
device; sharing a tab is the consent gesture. A pane in another tab is
refused with the same error as an unknown pane.

Closing one terminal of a split tab hands its device panes to the surviving
terminals instead of orphaning them.

The GUI registers a new split's session with the daemon a moment after the
session exists, so a device command racing that window can see a brief
refusal. Retry it.

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
deliberately visible to them; don't strip it from a subprocess environment. A
detached child (`setsid`, a daemonized process) remains authorized only while
its live parent chain reaches the tab, which is what lets an agent harness
drive the session it is running inside. Orphan it, so no live ancestor is left
in the terminal, and it is refused. So is a process elsewhere that copied the
cap: it has no ancestor in the tab at all.

### Escalate Only Through the GUI

Cross-tab input and capture require a live automation grant, and only the
GUI issues one, when a person opens an automation tab. There is no CLI verb
for escalation, and constructing the raw request by hand does not work: the
daemon refuses it from anything but the validated GUI.

A role string such as `"automation"` is descriptive metadata. Without a
live grant, cross-tab input and capture fail with `error.scope_violation`
even when `DEVICETERM_SESSION_ROLE` says `automation`.

[Open an Automation Tab](#open-an-automation-tab) covers the grant
lifecycle.

## Control the Workspace

### Open Tabs, Panes, and Windows

Create workspace surfaces from a script or agent:

```sh
deviceterm tab open --cwd "$PWD" --cmd 'make test'
deviceterm pane open --terminal --cwd "$PWD"
deviceterm window open
```

`tab open` mints a fresh tab, `pane open --terminal` splits the current tab
with another terminal pane, and `window open` mints a new window holding one
fresh tab. `--cmd` is typed into the new shell after attach, so the command
runs once and the shell stays interactive.

`tab open` and `window open` need a live automation grant, and an ordinary
tab is refused with `error.scope_violation`. `pane open --terminal` doesn't,
because it splits the tab the caller is already in. Naming another tab with
`--tab` does need one.

A success receipt means the GUI accepted the mutation for asynchronous
processing; it does not prove the change completed, and it does not return
the new session id. Confirm the outcome with the list commands; the event
stream cannot confirm it, because another session's lifecycle events are not
delivered to yours. Receipt shapes are defined in
[workspace receipts](INTEGRATION.md#workspace-receipts).

### Arrange, Select, and Close Surfaces

Reorder, retitle, focus, and close surfaces by reference:

```sh
deviceterm tab move --tab abc123 --to 0
deviceterm tab rename "auth-feature"
deviceterm tab select --tab abc123
deviceterm window focus --window 2
deviceterm tab close --mode shutdown
```

`tab move` also accepts `--to-window <ref>` to move the tab to another
window. `tab close` and `window close` take `--mode <detach|shutdown>` to
decide what happens to owned Simulators, the same decision the GUI close
prompt offers.

`tab select`, `tab move`, and `window focus` need a live automation grant,
including when the target is your own tab. An ordinary tab is refused with
`error.scope_violation`.

`tab rename` needs one only to leave your own tab. Without a grant you can
retitle a tab you own a terminal in, and nothing else.

`tab close` asks for more. Without a grant it reaches only a tab you own
*and* hold the single terminal of, because closing a split tab ends whatever
is running in the other panes, and those are other sessions. That is the
same outcome as closing someone else's tab, reached by a different route.

Either refusal arrives as daemon error `-32011`, with a message starting
`intent.automationRequired`, which is what separates a permission refusal
from a tab that isn't there.

`window close` inherits both rules, since it closes every tab in the window.
It refuses a window holding a tab you can't see, so it can't tear down a
co-hosted protected tab, and it refuses one holding any tab you don't
solely own.

`pane close` and `pane info` resolve Simulator panes only. Close a
physical-device pane in the GUI.

`pane close` takes the same `--mode <detach|shutdown>`, defaulting to
`detach`. The CLI never prompts, so `--mode` is how a script answers the
question the GUI asks.

`pane rename` and `pane move` are not implemented; see
[unsupported workspace verbs](INTEGRATION.md#unsupported-workspace-verbs).

## Discover State

### List Tabs, Panes, Windows, and Devices

```sh
deviceterm tabs list
deviceterm panes list
deviceterm windows list
deviceterm devices list
```

`tabs list` returns one row per live daemon session. Each GUI terminal pane has
a session, so a split tab produces several rows. In JSON mode, every row has a
required `tabId`. GUI terminal sessions in one tab share it; a session without
a GUI tab uses its `sessionId`.

Group rows without calling `tab info`:

```sh
rows=$(deviceterm tabs list --json) || exit $?

printf '%s\n' "$rows" |
  jq 'sort_by(.tabId) | group_by(.tabId)'

printf '%s\n' "$rows" |
  jq 'map(.tabId) | unique | length'
```

The second pipeline counts visible session groups. It equals the visible
GUI-tab count only when every visible session is GUI-backed; `tabs.list` does
not mark non-GUI groups.

The command shows unprotected sessions plus the protected rows visible to the
caller. `[]` with exit 0 is a successful empty visibility projection; failures
exit nonzero and emit a JSON error envelope. `tabs current` prints only the
caller's row.

`panes list` returns the device panes of the caller's tab.
`windows list` returns the caller's own window; add `--all` for every window
visible to the caller.

`devices list` reports DeviceTerm-owned booted Simulators and connected
physical devices. An externally booted Simulator stays absent until you
attach it; see [device roster rows](INTEGRATION.md#device-roster-rows).

Pass `--json` to any list for the machine-readable row shapes defined in
[Discovery and State](INTEGRATION.md#discovery-and-state).

### Check Health With doctor

```sh
deviceterm doctor
```

`doctor` checks the session environment, the `xcrun` shim, the daemon socket
and handshake, session authentication, linked device panes, and the methods
the daemon admits for this session. Use `--json` in a script and branch on
the exit status. The report shape and check names are defined in
[the doctor report](INTEGRATION.md#doctor-report).

### Diagnose Version Skew

After an upgrade, confirm the live daemon and the bundled CLI agree:

```sh
deviceterm version --json
```

Compare the `daemon` and `rpcWire` fields. A missing `daemon` field means the
version probe did not complete; it does not prove that no daemon is
reachable. Field semantics and a ready-made check are in
[the version report](INTEGRATION.md#version-report).

## Drive Other Tabs

### Open an Automation Tab

Open the tab with **Shell ▸ Open Automation Tab** or ⇧⌘T.

The GUI issues that tab's terminal session a live automation grant. The
grant lives in daemon memory and is checked on every request that needs it.
It's revoked when the tab closes, when the issuing GUI connection is lost, or
when the session ends.

The grant covers `tab capture` and `tab send-input`, plus `tab open`,
`tab select`, `tab move`, `window open`, and `window focus`. An ordinary tab
receives `error.scope_violation` for all seven, and the CLI cannot grant
authority to itself.

### Send Input to Another Tab

When `auth-feature` is known to name a GUI-backed session, discover its shared
full `tabId` and use it when work must run once per GUI tab:

```sh
rows=$(deviceterm tabs list --json) || exit $?

TARGET_TAB=$(
  printf '%s\n' "$rows" |
    jq -er '
      [.[] | select(.name == "auth-feature") | .tabId] |
      unique |
      if length == 1 then .[0]
      else error("expected exactly one matching tab")
      end
    '
)

deviceterm tab send-input --tab "$TARGET_TAB" 'make test\n'
```

`tabs.list` does not mark GUI-backed rows. If a non-GUI session can use the
same name, this selection is not reliable and its `tabId` will not resolve in
GUI workspace verbs.

The full `tabId` is accepted anywhere `--tab <ref>` is accepted. Short IDs
remain convenient for interactive use, but they identify individual session
rows and are not the grouping key for split tabs.

Instant input is dispatched before the command returns. With `--type-delay
<ms>`, typing is animated one character at a time and the command returns as
soon as the typing is enqueued, so it may still be running. Neither result
confirms that the target shell executed anything. Receipt fields and pacing
limits are defined in [send input](INTEGRATION.md#send-input).

### Capture Another Tab

```sh
deviceterm tab capture --tab "$TARGET_TAB"
```

The capture is the target's currently visible terminal viewport; scrollback
is not included. Human output is the raw text, so a redirect saves the
screen; `--json` wraps it as `{text}`. See
[capture a viewport](INTEGRATION.md#capture-a-viewport).

### Protect a Tab

Protect the current tab when other sessions should not see or control it:

```sh
deviceterm tab set-protected true
```

Every terminal session in the tab changes together. Other sessions cannot
list the protected tab or its panes, resolve its references, capture it, or
send input to it; your own sessions keep access. Automation grants do not
bypass protection, so an automation tab cannot capture or type into a tab
once that target is protected.

Only a tab the caller owns a terminal in can be flipped. The receipt's
`committed` field distinguishes a confirmed change from one the GUI is still
converging on; see [set protection](INTEGRATION.md#set-protection).

A protected tab's pill carries a lock in the tab strip, beside the wand if the
tab is also an automation tab. The lock follows what is hidden right now rather
than what the daemon has confirmed: it appears the moment you protect a tab,
and it stays on through an unprotect the daemon hasn't confirmed, so it can
disagree with the receipt's `committed` field while a change converges.

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
carrying a count or an ellipsis. Tree observation is the default. On a family
where the tree walk is unavailable, use a sweep:

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

Presentational roles rank last, entries with no `normalizedCenter` rank next to
last, and smaller frames rank first, so `matches[0]` is the element you are
most likely able to operate.

The ordering is a heuristic. To tap, take the first entry that carries a
`normalizedCenter` rather than assuming `matches[0]` does.

A truncated sweep that did not find the element is inconclusive rather than
proof that the element is absent. The failure carries the daemon's note as its
message, with `note` and `noteCode` in `details`. Branch on `noteCode`:
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
to refresh current state. Event shapes, ordering, and loss behavior are defined
in [Events](INTEGRATION.md#events).

An external Simulator can emit boot and shutdown events while staying absent
from `devices list`; use `xcrun simctl` when you need its metadata.
