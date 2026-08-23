# Automation Tab Manual Checklist

The Router tests cover the in-process path: the Router handles
`Route.openAutomationTab` by creating a session with `role: .automation`,
and the tab state records the granted role. This checklist covers the
*end-to-end UX* for automation tabs and tab-scoped device panes: menu and
tab-strip presentation, shell env propagation, sibling pane control,
protected-tab visibility, and terminal-close promotion.

Run before any release that touches `MainMenu`, `TabStripViewController`,
`Route.openAutomationTab` or its Router handler, `IntentDispatcher`,
the daemon's `session.create` handler, the Router's cohort machinery,
`PaneCoordinator`'s cohort authority, or the daemon's `session.setCohort`
handler.

## Preconditions

- A clean build: `make build`.
- No leftover app or daemon from this checkout: `make kill-daemon`.
- Launch with `make run`.

---

## 1. Open Automation Tab: happy path

| # | Action | Expected |
|---|--------|----------|
| 1.1 | Shell menu → look for "Open Automation Tab" | Item present with the ⌘⇧T shortcut (⌘T stays the muscle-memory default for a plain tab, so an automation tab isn't opened by accident). |
| 1.2 | Click it | A new tab opens with a live shell, as with regular New Tab. |
| 1.3 | Inspect the new tab's title in the tab strip | A small accent-colored wand icon (SF Symbol `wand.and.rays`, 12pt) appears immediately to the left of the title. |
| 1.4 | Mouse-hover the icon | Tooltip reads "Automation tab (opened from the menu)" (the text lives in `TabStripViewController.automationMarker`). |
| 1.5 | Open a second regular tab (⌘T) | The new tab has NO wand icon: only automation tabs are marked. |

## 2. Automation role visible to the CLI

| # | Action | Expected |
|---|--------|----------|
| 2.1 | Inside the automation tab's shell: `env \| grep DEVICETERM_SESSION_ROLE` | Prints `DEVICETERM_SESSION_ROLE=automation`. |
| 2.2 | `deviceterm help` (first line) | The "Command reference" prefix shows `session role: automation`. |
| 2.3 | `deviceterm doctor` (a beat after the shell appears) | Reports `role: automation`. `tab.sendInput` / `tab.capture` **are** in `allowedMethods`: the GUI grants the tab's session once its terminal binds, and advertising follows the live grant. (Run immediately at spawn and you may briefly see them absent before the bind+grant lands; re-run.) |
| 2.4 | Inside a regular agent tab: `deviceterm doctor` | Reports `role: agent` for contrast. |

## 3. Trust boundary: automation mint is refused off the GUI path

The daemon enforces "human-only escalation" rather than assuming it.
An automation mint arriving over UDS is refused outright; over XPC
it is accepted only after the peer's audit token validates against
the daemon's own code signature.

**Setup.** Open any tab (agent role is fine) so the shell has
`DEVICETERM_DAEMON_SOCK` set.

| # | Action | Expected |
|---|--------|----------|
| 3.1 | Send a raw `session.create` with `role: "automation"` over the daemon socket (see below) | Error `-32011`, message `automation sessions can only be minted from the GUI`. |
| 3.2 | Repeat with `role: "agent"` | Succeeds: proves the socket path works and only the role is refused. |
| 3.3 | `deviceterm tab capture` inside an automation tab (against a second, unprotected tab: `deviceterm tab capture --tab <shortId>`) | **Succeeds**: prints the target tab's visible text. The GUI granted this tab's session after its terminal bound, and the CLI authenticates over UDS via the bound terminal, so the live-grant scope check admits it. |
| 3.4 | The same `deviceterm tab capture` inside a **regular agent tab** | Fails with `-32011`, "this session has no live automation grant…". An agent tab is never granted, so the elevated verbs stay refused. |

## 3a. Grant lifecycle: reconnect and close

| # | Action | Expected |
|---|--------|----------|
| 3a.1 | In a working automation tab, find this checkout's daemon pid with `./scripts/instance-guard.sh status` (the row marked `mine`) and `kill -9` it, leaving the GUI running; wait for the pane to recover | After the GUI reconnects and rebinds the terminal, it **reissues** the grant. `deviceterm tab capture` works again (the daemon's in-memory grant store was lost on restart; reissue-on-reconnect repopulates it). |
| 3a.2 | Close the automation tab, then in another tab try to reach its (now-dead) session | The grant is gone: closing the tab called `session.close`, and the daemon revokes on session removal. No lingering authority. |

The raw frame is `[uint32 BE length][JSON]`:

```sh
python3 - <<'EOF'
import json, os, socket, struct
body = {"id": 1, "type": "request", "method": "session.create",
        "params": {"role": "automation"}}
raw = json.dumps(body).encode()
s = socket.socket(socket.AF_UNIX)
s.connect(os.environ["DEVICETERM_DAEMON_SOCK"])
s.sendall(struct.pack(">I", len(raw)) + raw)
n = struct.unpack(">I", s.recv(4))[0]
print(s.recv(n).decode())
EOF
```

The GUI's XPC side of the same gate (a Developer-ID-signed build
accepted, an ad-hoc re-sign rejected) is covered by
`launchd-xpc-coexistence.md` §4, which needs a real signed bundle.

## 3b. Cross-tab reach without a grant

| # | Action | Expected |
|---|--------|----------|
| 3b.1 | From a plain agent tab, `deviceterm tab close` with no `--tab` | Closes that tab. It's the caller's own and holds one terminal. |
| 3b.2 | Open a second plain tab. From the first, `deviceterm tab rename --tab <second> x` | Refused, `-32011`, message names `intent.automationRequired`. |
| 3b.3 | Split a tab with `pane open --terminal`, then from one pane run `deviceterm tab close` | Refused: the tab now holds two sessions. |
| 3b.4 | Close the split back to one terminal, retry `deviceterm tab close` | Closes. |
| 3b.5 | Repeat 3b.2 from an Automation Tab | Succeeds. |
| 3b.6 | From a plain tab, `deviceterm pane open --terminal --tab <other>` | Refused, `-32011`. |

---

## 4. GUI menu under stress

| # | Action | Expected |
|---|--------|----------|
| 4.1 | Quit DeviceTerm; relaunch | The automation-tab menu still works: re-opening an automation tab from the Shell menu mints a fresh automation session. |
| 4.2 | Open multiple automation tabs in succession | Each gets its own session + its own wand-icon marker; closing one doesn't affect the others. |

---

## 5. Tab-scoped device panes

The daemon scopes device-pane control to the tab through a session cohort
the GUI keeps reconciled with the tab's terminals. Needs one bootable
Simulator.

| # | Action | Expected |
|---|--------|----------|
| 5.1 | Split a plain tab twice (`deviceterm pane open --terminal`, twice), then in the **last** terminal run `xcrun simctl boot <udid>` | The sim pane mounts in this tab. |
| 5.2 | Still in that last terminal: `deviceterm tap 0.5 0.5` | Lands. The booting terminal drives the sim even though it is not the tab's primary terminal (attribution reads the primary; authority reads membership). |
| 5.3 | From a different terminal in the same tab: `deviceterm panes list`, then the same `tap` | The pane is listed and the tap lands: siblings drive the tab's panes. |
| 5.4 | `deviceterm tab set-protected true`, then from a non-primary terminal: `deviceterm devices list` | The tab's sim shows as attached. Protection hides the tab from other sessions, not from its own terminals. |
| 5.5 | Exit the shell in the terminal that booted the sim (closing that terminal pane) | The sim pane stays mounted and rendering, and the surviving terminals still drive it: the close promoted the pane to them. |

---

## Pass criteria

- §1: menu item present, opens a tab, wand icon visible only on the
  automation tab.
- §2: `DEVICETERM_SESSION_ROLE` env var set; `deviceterm help` /
  `deviceterm doctor` report automation.
- §3: a raw UDS `session.create` with `role: "automation"` is
  refused with `-32011`; the same request as `agent` succeeds;
  `deviceterm tab capture` works from inside an automation tab and
  is refused (`-32011`) from an agent tab.
- §3a: cross-tab authority is restored after a daemon respawn, because
  the GUI reissues the grant on reconnect, and is gone after the tab closes.
- §3b: a plain tab closes and renames only itself, and `tab close` refuses
  once the tab holds a second terminal; an Automation Tab does all of it.
- §4: automation-tab menu survives quit/relaunch and supports
  multiple concurrent automation tabs.
- §5: siblings list and drive the tab's sim, protection doesn't hide a
  tab's own device from its own terminals, and closing the booting
  terminal leaves the pane with the survivors.
