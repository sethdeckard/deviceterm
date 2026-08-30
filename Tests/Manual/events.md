# `deviceterm events` Manual Checklist

The DaemonEvent wire shape, EventBroker fan-out, and SessionManager
publish wiring are covered by unit tests. This checklist covers the
*end-to-end runner* the unit tests can't see: the CLI's long-running
UDS subscription, the event-by-event JSON output, and the actual
publish wiring on each coordinator path.

Run before any release that touches `Sources/Daemon/EventBroker.swift`,
`Sources/Daemon/DaemonEventsMethods.swift`, the publish sites in
`PaneCoordinator` / `DeviceCoordinator` / `SessionManager`, or the
`.events` dispatch in `DeviceTermCLI/main.swift`.

## Preconditions

- A clean build: `make build`.
- Launch with `make run`. Open one tab (this opens the GUI + spawns the
  daemon).

## Scope

`deviceterm events` is **session-scoped**: it must run **inside a
DeviceTerm tab** (it reads `DEVICETERM_SESSION` + cap from the env to
authenticate). It shows: this session's pane state changes, this
session's own `session.closed`, and every device boot/shutdown
(device events reach all sessions). Another tab's pane events and
session-lifecycle are **not** visible to a CLI runner: only the GUI
process (validated over XPC) spans sessions. So run `events` and
trigger the pane action **from the same terminal pane's shell**: a
sibling terminal pane is a different session. An out-of-tab runner is
rejected (see §7).

---

## 1. Stream start + initial output

| # | Action | Expected |
|---|--------|----------|
| 1.1 | **Inside the DeviceTerm terminal pane's shell**, background a subscriber: `deviceterm events &`. | Process attaches to the daemon and waits. No output yet. Stays running. |
| 1.2 | In the **same terminal pane's shell**, run `xcrun simctl boot <UDID>` (the shim intercepts). | Within ~1s the events output shows one or two JSON lines: `{"…","type":"device.booted","udid":"…"}` and `{"…","type":"pane.stateChanged","paneId":"…","state":"booting","udid":"…"}`. |
| 1.3 | Wait a few seconds for the sim to render. | The events output shows `{"…","type":"pane.stateChanged","paneId":"…","state":"rendering","udid":"…"}`. |

## 2. Session lifecycle events

The CLI runner sees only its **own** session's lifecycle; another
tab's `session.created` / `session.closed` is visible to the GUI, not
to a session-scoped CLI subscriber.

| # | Action | Expected |
|---|--------|----------|
| 2.1 | Open a new tab (Cmd+T) and confirm the §1 subscriber does **not** print a `session.created` for it. | No output on the §1 subscriber (the new tab is a different session; the event is scoped to it). |
| 2.2 | Close the tab running the §1 subscriber (Cmd+W; Detach or Shut Down at the prompt). | Just before the stream ends on EOF, it may print its own `{"…","type":"session.closed","sessionId":"…"}`; then the process exits. |

## 3. Device shutdown event

| # | Action | Expected |
|---|--------|----------|
| 3.1 | Use the menu-bar status item's "Shut Down <sim>" entry, OR run `xcrun simctl shutdown <UDID>` in a tab. | Within ~1s: `{"…","type":"device.shutdown","udid":"…"}` (potentially followed by a `pane.stateChanged` with state `shutdown` if the pane was attached). |

## 4. Multiple subscribers (fan-out)

| # | Action | Expected |
|---|--------|----------|
| 4.1 | In the **same terminal pane's shell**, start a second subscriber (`deviceterm events &` again), so two subscribers share the session. | Both run silently. |
| 4.2 | Trigger a sim boot or shutdown. | BOTH subscribers print the same JSON lines (`device.*` reaches every session; the shared session's `pane.stateChanged` reaches both). Fan-out works. |

## 5. JSON validity + jq filtering

| # | Action | Expected |
|---|--------|----------|
| 5.1 | `deviceterm events \| jq -c .` | Every line is valid JSON; jq prints them back out compactly without errors. |
| 5.2 | Background `deviceterm events \| jq --unbuffered 'select(.type=="pane.stateChanged" and .state=="rendering")' \| head -n 1`, then boot a sim from the same shell. | Prints one JSON line when the pane reaches `rendering`, then exits cleanly. This validates live event delivery only. The stream has no replay and is not a reliable wait primitive; use `deviceterm wait pane rendering` for synchronization. |
| 5.3 | `deviceterm events --json`: confirm `--json` is accepted but no-op (the stream is always JSON). | Same output as bare `deviceterm events`. |

## 6. Connection teardown

| # | Action | Expected |
|---|--------|----------|
| 6.1 | While `deviceterm events` is running, kill the daemon (`pkill deviceterm-daemon` or shut down via menu-bar). | The events process exits cleanly (exit 0) on EOF. |
| 6.2 | Ctrl-C the events process. | Process exits; no daemon-side error in logs. |

## 7. No-tab + bad socket paths

| # | Action | Expected |
|---|--------|----------|
| 7.1 | Run `deviceterm events` in a plain terminal **outside** any DeviceTerm tab (no `DEVICETERM_SESSION` in env). | Stderr: `deviceterm events requires an authenticated, live deviceterm tab session`; exit 1. (Session-scoped: the scope gate rejects the unauthenticated subscribe.) |
| 7.2 | `DEVICETERM_DAEMON_SOCK=/tmp/no-such-socket deviceterm events`. | `events` connects straight to the UDS path and does not demand-launch, so an unreachable socket is terminal: stderr `deviceterm: cannot connect to daemon at /tmp/no-such-socket: …`; exit 1. |

---

## Pass criteria

- §1: Same-session boot fires `device.booted` + `pane.stateChanged{booting}`; render fires `pane.stateChanged{rendering}`.
- §2: A CLI runner sees only its **own** session's lifecycle; another tab's `session.created` is not visible to it.
- §3: Shutdown fires `device.shutdown` (and `pane.stateChanged{shutdown}` if applicable).
- §4: Same-session multi-subscriber fan-out works.
- §5: Output is jq-pipeable; live `pane.stateChanged` delivery works, with no
  claim that the stream is a wait primitive.
- §6: Clean teardown on daemon EOF or Ctrl-C.
- §7: Out-of-tab `events` is rejected with the must-run-inside-a-tab message.

There is no committed run-log: the fix commits are the record.
