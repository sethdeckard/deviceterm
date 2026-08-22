# Automating DeviceTerm

Use the `deviceterm` CLI to control DeviceTerm itself: open and arrange tabs,
panes, and windows, inspect workspace state, drive other tabs from an
automation tab, and wait on events. The caller can be a person at a prompt,
a script, an agent, or a program coordinating several agents; the commands
and the rules are the same.

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
- [Wait on Events](#wait-on-events)

## Understand Tabs, Sessions, and Authority

Authority has three tiers. Device panes are contained to the session that
currently owns them. Workspace commands reach any unprotected tab the caller
can see.
Reading another tab's contents or typing into it requires a live
automation grant that only the GUI can issue.

The grant sits where it does because capture and input reach another
session's contents: what its terminal shows and what runs in it. Workspace
commands touch arrangement and lifecycle, never contents, and the structure
of unprotected tabs is deliberately shared. A tab that should be untouchable
opts out of every tier with [`tab set-protected`](#protect-a-tab).

### Know Your Session

DeviceTerm injects a session identity into every terminal pane's shell:
`DEVICETERM_SESSION` holds the session id, `DEVICETERM_SESSION_CAP` holds the
session credential, and companion variables locate the daemon socket and the
per-session shim directory. The CLI reads them transparently; no command
takes a credential flag or operand.

A terminal split is its own session. The GUI treats the tab as one workspace,
but each terminal pane carries a separate CLI identity with its own
credential.

Device panes are linked to an owning session, and every pane-targeted
command is authorized against the current ownership. Your session drives
only its own panes; a pane owned by a sibling terminal pane is refused with
the same error as an unknown pane, even inside your own tab.

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

These verbs reach any unprotected tab visible to the caller, not only your
own. A `tab close --tab <ref>` naming another session's unprotected tab
closes it, ending whatever was running there; protect a tab when other
sessions should not be able to touch it.

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

`tabs list` returns one row per live terminal session, so a split tab
produces several rows. It shows unprotected sessions plus your own protected
ones.
`tabs current` prints only the caller's row.

`panes list` returns the device panes owned by the calling session.
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
grant lives in daemon memory and is checked on every cross-tab request; it is
revoked when the tab closes, when the issuing GUI connection is lost, or when
the session ends. An ordinary tab receives `error.scope_violation` for
cross-tab capture and input, and the CLI cannot grant authority to itself.

### Send Input to Another Tab

List the visible sessions and target one by short id:

```sh
deviceterm tabs list
TARGET_TAB="abc123"
deviceterm tab send-input --tab "$TARGET_TAB" 'make test\n'
```

Replace `abc123` with a short id printed by `tabs list`.

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

## Wait on Events

### Choose Polling or Events

`deviceterm events` streams the current session's pane transitions and
session close, plus global Simulator boot and shutdown transitions, one JSON
object per line:

```sh
deviceterm events
```

Treat the list commands as the source of current truth and the stream as a
low-latency signal to refresh that truth. Event shapes, ordering, and loss
behavior are defined in [Events](INTEGRATION.md#events).

An external Simulator can emit boot and shutdown events while staying absent
from `devices list`; use `xcrun simctl` when you need its metadata.

### Subscribe Before Triggering Work

The stream has no replay or durable journal. Events published before the
subscription is established are not delivered later.

This sequence can miss the rendering transition and wait forever:

```sh
xcrun simctl boot "$UDID"
deviceterm events \
  | jq --unbuffered \
      'select(.type == "pane.stateChanged" and .state == "rendering")'
```

Starting the subscriber first reduces the race, but the CLI does not emit a
public readiness record. A fixed delay cannot prove that the subscription is
active.

The following recipes run `simctl boot` synchronously. Their deadline begins
after that command returns, so it bounds the rendering wait but does not bound
a stalled boot command. Apply a command timeout appropriate to your automation
environment if that failure mode must also be bounded.

### Poll for the Final State

Use current-state polling when you only need the final state:

```sh
UDID="<simulator-udid>"

if ! xcrun simctl boot "$UDID"; then
  printf 'failed to boot Simulator %s\n' "$UDID" >&2
  exit 1
fi

deadline=$(( $(date +%s) + 30 ))
while ! deviceterm panes list --json \
    | jq -e --arg udid "$UDID" \
        'any(.[];
          (.udid | ascii_downcase) == ($udid | ascii_downcase)
          and .state == "rendering"
        )' \
    >/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    printf 'timed out waiting for Simulator %s\n' "$UDID" >&2
    exit 1
  fi
  sleep 0.2
done
```

### Combine Events With Current State

For lower latency without an indefinite rendering wait, start the subscriber
first and poll the same target as a fallback:

```sh
UDID="<simulator-udid>"
EVENT_FILE="$(mktemp -t deviceterm-events)"

deviceterm events > "$EVENT_FILE" &
EVENTS_PID=$!

cleanup_events() {
  trap - EXIT HUP INT TERM
  kill "$EVENTS_PID" 2>/dev/null || true
  wait "$EVENTS_PID" 2>/dev/null || true
  rm -f "$EVENT_FILE"
}
trap cleanup_events EXIT
trap 'exit 1' HUP INT TERM

if ! xcrun simctl boot "$UDID"; then
  printf 'failed to boot Simulator %s\n' "$UDID" >&2
  exit 1
fi

DEADLINE=$(( $(date +%s) + 30 ))
while ! jq -e -s --arg udid "$UDID" \
    'any(.[];
      .type == "pane.stateChanged"
      and (((.udid? // "") | ascii_downcase) == ($udid | ascii_downcase))
      and .state == "rendering"
    )' \
    "$EVENT_FILE" >/dev/null 2>&1; do
  deviceterm panes list --json \
    | jq -e --arg udid "$UDID" \
        'any(.[];
          (.udid | ascii_downcase) == ($udid | ascii_downcase)
          and .state == "rendering"
        )' \
    >/dev/null && break

  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    printf 'timed out waiting for Simulator %s to render\n' "$UDID" >&2
    exit 1
  fi

  sleep 0.2
done

cleanup_events
```

The state query covers an event that fired before subscription readiness. It
also provides the recovery path if the daemon restarts and closes the stream.

The cleanup function stops the whole subscriber process and waits for it. The
deadline bounds the rendering wait after `simctl boot` returns.
