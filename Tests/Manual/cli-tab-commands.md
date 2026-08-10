# Workspace CLI Verbs Manual Checklist

End-to-end check that the daemon → GUI back-channel routes each new
verb to a live action the user can see. Run from inside a DeviceTerm tab
(so `DEVICETERM_SESSION` / `DEVICETERM_SESSION_CAP` are populated and the
caller's "current" tab resolves).

The CLI side is hermetic-testable in `WorkspaceCommandsTests`; this
file pins the *visible* outcome: a GUI mutation matching the verb, an
echo line on stdout, an exit code of 0 on success.

## Setup

1. Build a debug app: `make build`.
2. Launch the daemon-bundled app: `make run`. Wait for one window with
   one tab.
3. In that tab's shell, confirm `deviceterm tabs current` prints a row.
   If it errors, the env isn't seeded — close the tab and open a new
   one.

## Tab verbs

### `deviceterm tab open`

```
$ deviceterm tab open
ok window=current
```

- A new tab appears in the same window. With no `--cwd`, it opens
  in the GUI login-shell's default working directory.
- Exit code: `0`.

### `deviceterm tab open --window 1`

```
$ deviceterm tab open --window 1
ok window=1
```

- New tab appears in window index 1 (i.e. the first / only window).

### `deviceterm tab info`

```
$ deviceterm tab info
session: <UUID>
shortId: abc123
role:    agent
current: true
...
```

- Caller's own tab info prints in column form.
- `--json` returns the raw `TabInfoPayload` JSON object.

### `deviceterm tab rename "billing-feature"`

```
$ deviceterm tab rename "billing-feature"
ok tab=current name=billing-feature
```

- The tab strip's title updates to "billing-feature" immediately.
- Run again with no args (`deviceterm tab rename`) and the title falls
  back to the automatic label.

### `deviceterm tab select --tab <shortId-of-another-tab>`

```
$ deviceterm tab select --tab def456
ok tab=def456
```

- Selection visually moves to the named tab.

### `deviceterm tab close`

```
$ deviceterm tab close
ok tab=current mode=detach
```

- The originating tab closes. If the window has other tabs, focus
  shifts to a neighbor. If it was the last tab, the window closes too
  (matches the existing close-last-tab flow).
- The shell that ran the verb dies with it; subsequent commands in
  that shell don't run.

## Pane verbs

### `deviceterm pane info`

When the tab has a sim pane:

```
$ deviceterm pane info
paneId:  <UUID>
udid:    <UUID>
display: iPhone 17 Pro
family:  iPhone
session: <UUID>
```

When the tab has no sim pane:

```
$ deviceterm pane info
deviceterm: daemon error -32099: intent.notFound: pane 'current (no sim panes in tab)' not found
```

(Exit code: `1`.)

### `deviceterm pane open --terminal`

```
$ deviceterm pane open --terminal
ok tab=current
```

- A second terminal pane appears alongside the existing one,
  splitting the tab. It does not open a new tab.

### `deviceterm pane close --pane <shortId>`

Requires a sim pane present. Resolve the shortId from `deviceterm panes
list`, then:

```
$ deviceterm pane close --pane <shortId>
ok pane=<shortId> mode=detach
```

- The sim pane detaches from the tab; the booted sim stays running
  unless `--mode shutdown` was used.

### `deviceterm pane rename` / `pane move`

These are not implemented; running them surfaces the daemon's
`intent.internalError` carrying a `pane <verb> is not implemented` hint.
Exit code: `1`. Confirm the error message text references the missing
implementation so a future fix doesn't silently slip in.

(There is no `pane attach` subverb. Claiming an already-booted sim or a
connected device into the current tab is `deviceterm device attach
<ref>`.)

## Window verbs

### `deviceterm window open`

```
$ deviceterm window open
ok
```

- A new window appears with one fresh agent-role tab.

### `deviceterm windows list`

```
$ deviceterm windows list
*       1       1       abc123
        2       1       def456
```

- One row per visible window. Marker `*` on the key window.
- `--json` emits a `[WindowInfoPayload]` array.

### `deviceterm window focus --window 2`

```
$ deviceterm window focus --window 2
ok window=2
```

- Window index 2 comes forward and becomes key.

### `deviceterm window close --window 2`

```
$ deviceterm window close --window 2
ok window=2 mode=detach
```

- Window index 2 closes (with the close-with-sims prompt if any sims
  are linked to its tabs).

## Failure modes worth eyeballing

- **No GUI subscribed** — quit DeviceTerm and run any workspace
  verb from a stranded tab: daemon returns
  `intent.guiUnavailable` (timeout = `5s`).
- **Unresolved ref** — `deviceterm tab close --tab no-such-tab`: daemon
  returns `intent.notFound`.
- **Ambiguous ref** — if two tabs share the same `name`, `deviceterm tab
  select --tab "auth"` returns `intent.ambiguous`.

## Pass criteria

All of:

- Every verb's "happy path" above prints the expected `ok …` line and
  exits `0`.
- Every unimplemented verb (`pane rename`, `pane move`) reaches the
  daemon and returns the documented `intent.internalError` (exit `1`).
- No verb leaves a tab/window in a half-built state (no orphan
  windows, no zombie tabs).
- `deviceterm help` lists `tab`, `pane`, `window`, and `windows` under
  "Manage the workspace", and `deviceterm help tab` shows every tab
  subcommand plus the ref legend.
