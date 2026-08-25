# DeviceTerm Integration Guide

This guide is the machine contract for the `deviceterm` CLI: the public JSON
shapes, authorization scopes, completion semantics, and stability promises.
Most users can continue using `xcrun simctl` and `xcrun devicectl` without
consuming these contracts.

Use `deviceterm help` for command syntax and `deviceterm agents` for
in-terminal automation notes. Workflows live in the companion guides:
[`AUTOMATION.md`](AUTOMATION.md) for workspace control, automation, and
events, and [`USAGE.md`](USAGE.md) for driving devices inside a tab.

## Contents

- [Contract Rules](#contract-rules)
- [Surface Matrix](#surface-matrix)
- [Discovery and State](#discovery-and-state)
- [Action Receipts](#action-receipts)
- [Accessibility](#accessibility)
- [Automation](#automation)
- [Events](#events)

## Contract Rules

### Select Machine-Readable Output

Pass `--json` to commands that normally provide human-readable lists, reports,
or receipts:

```sh
deviceterm panes list --json
deviceterm tap 0.5 0.5 --json
deviceterm doctor --json
```

The flag is global and may appear before or after a command's operands.

These commands always emit JSON, with or without `--json`:

- `ax tree`
- `ax point`
- `ax sweep`
- `events`, as one JSON object per line

These commands have no DeviceTerm JSON output:

- `help`
- `agents`
- `completions install`
- `with-pane`

`with-pane` inherits its child process's stdout and stderr. The child may emit
JSON independently.

### Read Stdout, Stderr, and Exit Status Separately

Successful JSON goes to stdout with a trailing newline. Errors remain
human-readable text on stderr, even when you pass `--json`.

DeviceTerm does not emit JSON error envelopes. Check the process exit status
before decoding stdout:

```sh
if report=$(deviceterm doctor --json); then
  printf '%s\n' "$report" | jq '.checks'
else
  status=$?
  printf '%s\n' "$report" | jq '.checks' 2>/dev/null || true
  exit "$status"
fi
```

Most command, usage, transport, and daemon failures exit with status 1.
Special cases are:

| Command | Exit Behavior |
|---|---|
| `doctor` | 0 when no check has `status: "fail"`; otherwise 1 |
| `events` | 0 when the daemon closes the stream normally |
| `with-pane` | Child exit status, or `128 + signal` when signaled |
| `with-pane` spawn failure | 127 |

Exact error sentences are diagnostic prose. Do not parse them as a structured
contract.

### Handle Objects and Optional Fields Defensively

JSON object order is not significant. DeviceTerm currently sorts many locally
encoded receipt keys for deterministic tests, but integrations must not depend
on key order.

A missing optional value normally omits its key instead of emitting `null`:

```json
{"ok":true,"paneId":"P1","udid":"U1","x":0.5,"y":0.5}
```

This receipt has no `shortId` key. Test key presence instead of comparing with
`null`:

```sh
deviceterm tap 0.5 0.5 --json | jq 'has("shortId")'
```

Ignore unknown keys and tolerate unknown enum values. Compatible releases may
add optional fields, event types, capability flags, or enum cases.

### Apply the Stability Categories

The public CLI, JSON output, and exit behavior follow DeviceTerm's release
version.

During 0.x, a minor release may introduce breaking public changes. Patch
releases remain compatible within the same minor series. Starting with 1.0,
breaking public changes require a new major release.

This guide uses three stability categories:

| Category | Promise |
|---|---|
| Stable | Existing names, types, and semantics change only through the applicable SemVer boundary |
| Stable-additive | The existing shape has the stable promise, but compatible releases may add optional fields or enum values |
| Best-effort | The value depends on Apple frameworks, runtime behavior, or diagnostic prose and may change without defining a DeviceTerm JSON compatibility boundary |

DeviceTerm-owned JSON receipts, payloads, and wrapper fields are
stable-additive unless this guide says otherwise. Human output, diagnostic
details, and Apple-sourced accessibility nodes are best-effort.

### Separate Release and Wire Versions

`deviceterm version` reports one public release version and two internal wire
versions:

- `deviceterm` is the public release version governing the CLI and JSON
  contract.
- `daemon` is the live daemon's internal wire version.
- `rpcWire` is the internal wire version expected by the bundled CLI.

Compare `daemon` with `rpcWire` when diagnosing an interrupted update. The
public `deviceterm` version does not need to equal either internal value.

`DaemonProtocolInfo.wireVersion` coordinates the bundled app, daemon, CLI, and
shim. It is not an end-user compatibility version and must not select your JSON
decoder.

### Distinguish Identifiers

DeviceTerm exposes several identifier layers:

| Field | Meaning |
|---|---|
| `sessionId` | Daemon session UUID. Each terminal session has one, so a split tab can have several |
| `paneId` | UUID for one device pane |
| `shortId` | Short display and reference handle. Optional during version skew |
| `name` | Optional human-assigned or creation-time name. It may be absent or ambiguous |
| `displayTitle` | Live GUI title. It is display metadata, not an identifier |
| `udid` in a pane | The pane's device key: a Simulator UDID or physical CoreDevice device ID |
| `id` in the device roster | A Simulator UDID or physical CoreDevice device ID |

Workspace receipts generally echo the reference supplied by the caller, such
as `"current"` or `"abc123"`. They do not promise to replace it with a resolved
UUID.

### Respect Authorization Scope

The CLI reads session credentials from the DeviceTerm tab environment. Do not
add credential flags or pass `DEVICETERM_SESSION_CAP` as a command operand.

The capability is only one authentication factor. The daemon also checks that
the caller, or one of its live ancestors, belongs to the terminal bound to that
session, and repeats the provenance check for scoped requests.

This guide uses four scope labels:

| Scope | Requirement |
|---|---|
| Local | No daemon connection |
| Daemon-wide | Daemon connection, but no authenticated tab required |
| Session | Live authenticated DeviceTerm terminal session |
| Automation | Session scope plus a live automation grant issued by the GUI |

A role such as `"automation"` is descriptive metadata. The commands marked
Automation below require a live grant, not the role string alone. Only the
GUI issues a grant; see [`AUTOMATION.md`](AUTOMATION.md#drive-other-tabs).

Protected sessions remain opaque to other callers. Lists omit protected
sessions, panes, and ownership annotations unless the caller owns that
protected tab.

## Surface Matrix

| Command | Machine Output | Scope | Completion Meaning | Stability |
|---|---|---|---|---|
| `tabs list --json` | Array of tab rows | Daemon-wide | Current visible session snapshot | Stable-additive |
| `tabs current --json` | One tab row | Current session environment | Matching live session found | Stable-additive |
| `panes list --json` | Array of pane rows | Session | Current device panes of the caller's tab | Stable-additive |
| `devices list --json` | Array of device roster rows | Session | Current owned-Simulator and connected-device snapshot | Stable-additive |
| `windows list --json` | Array of window rows | Daemon-wide | Current caller-visible window projection | Stable-additive |
| `tab info --json` | Tab information object | Session | Current GUI workspace snapshot | Stable-additive |
| `pane info --json` | Simulator pane information object | Session | Current GUI workspace snapshot | Stable-additive |
| `doctor --json` | Doctor report | None required; session fields are conditional | Checks completed | Stable-additive except diagnostic prose |
| `version --json` | Version report | Local, with optional daemon probe | Local report completed | Stable-additive |
| `dump-config --json` | Configuration report | Local | Configuration file parsed | Stable-additive |
| `tap`, `swipe`, `app-switcher`, `long-press`, `pinch` with `--json` | Input receipt | Session | Daemon completed the input dispatch call | Stable-additive |
| `button`, `key`, `text`, `rotate`, `crown` with `--json` | Input receipt | Session | Daemon completed the input dispatch call | Stable-additive |
| `tab rename` with `--json` | Workspace receipt | Session and tab ownership, or automation | GUI returned success for the requested mutation | Stable-additive |
| `tab close` with `--json` | Workspace receipt | Session and sole-terminal tab ownership, or automation | GUI returned success for the requested mutation | Stable-additive |
| `tab open`, `tab select`, `tab move` with `--json` | Workspace receipt | Automation | GUI returned success for the requested mutation | Stable-additive |
| `pane open --terminal`, `pane close` with `--json` | Workspace receipt | Session and tab ownership, or automation | GUI returned success for the requested mutation | Stable-additive |
| `device attach --json` | Device attachment receipt | Session | GUI accepted the attachment; rendering may still be pending | Stable-additive |
| `window close` with `--json` | Workspace receipt | Session and sole-terminal ownership of every tab in the window, or automation | GUI returned success for the requested mutation | Stable-additive |
| `window open`, `window focus` with `--json` | Workspace receipt | Automation | GUI returned success for the requested mutation | Stable-additive |
| `tab set-protected --json` | Protection receipt | Session and tab ownership | Reports whether the requested state was confirmed | Stable-additive |
| `tab send-input --json` | Input receipt | Automation | Instant input was dispatched; positively paced typing was enqueued and may still be running | Stable-additive |
| `tab capture --json` | `{text}` | Automation | Visible viewport captured | Stable-additive |
| `ax tree`, `ax point` | DeviceTerm wrapper containing an Apple accessibility node | Session | Accessibility query completed | Stable-additive wrapper; best-effort node |
| `ax sweep` | DeviceTerm sweep wrapper containing Apple nodes | Session | Sweep completed | Stable-additive wrapper; best-effort children |
| `events` | JSON Lines stream | Session | Subscription remains active until EOF or termination | Stable-additive |
| `with-pane` | Child-owned stdout and stderr | Session | Child process exited | Stable exit forwarding |
| `pane rename`, `pane move` | No success shape | Session | Unsupported; command fails | Stable unsupported status |
| `help`, `agents` | Prose | Local, with optional daemon discovery | Documentation printed | Not a JSON contract |
| `completions install` | Prose and a written completion file | Local | Completion file installed | Not a JSON contract |

## Discovery and State

### Version Report

Run:

```sh
deviceterm version --json
```

Shape:

```jsonc
{
  "deviceterm": "0.1.0",
  "daemon": "0.1.0",  // optional; omitted when the live probe fails
  "rpcWire": "0.1.0",
  "macOS": "26.4.1"
}
```

All fields except `daemon` are required.

For update diagnosis:

```sh
report=$(deviceterm version --json)

if ! printf '%s\n' "$report" | jq -e 'has("daemon")' >/dev/null; then
  printf 'daemon version probe did not succeed\n' >&2
  exit 1
fi

if ! printf '%s\n' "$report" | jq -e '.daemon == .rpcWire' >/dev/null; then
  printf 'daemon and bundled RPC wire versions differ\n' >&2
  exit 1
fi
```

A missing `daemon` field means the live version probe did not succeed. It does
not distinguish an unreachable daemon from authentication, transport, RPC, or
decoding failure. Handle that case separately from a present mismatch between
`daemon` and `rpcWire`, which indicates an interrupted or incomplete update.

### Configuration Report

Run:

```sh
deviceterm dump-config --json
```

Shape:

```json
{
  "entries": [
    {
      "key": "auto-update",
      "value": "check",
      "source": "default"
    },
    {
      "key": "quit-with-sims-default",
      "value": "",
      "source": "unset",
      "note": "the Quit prompt is shown; set keep or shutdown to suppress it"
    },
    {
      "key": "tab-close-default",
      "value": "shutdown",
      "source": "file"
    }
  ],
  "warnings": [
    "unknown config key: typo-here"
  ]
}
```

`entries` and `warnings` are always present. Each entry has:

| Field | Type | Meaning |
|---|---|---|
| `key` | string | Recognized DeviceTerm configuration key |
| `value` | string | Effective value; empty when `source` is `"unset"` |
| `source` | string | `"default"`, `"file"`, or `"unset"` |
| `note` | string, optional | Present only on `"unset"` entries; what the app does while the key is absent |

`tab-close-default` and `quit-with-sims-default` apply no default when
absent: the app shows the prompt. Their absent entries report
`source: "unset"` with an empty `value` and an explanatory `note` rather
than claiming the documented default is effective. Keys whose default
genuinely applies on absence (`simulator-app-advisory`, `auto-update`,
`tab-close-multi-pane`) keep reporting `source: "default"`.

Entries are sorted by key. Warning text is diagnostic prose and best-effort.

### Tab Rows

`tabs list --json` returns an array. `tabs current --json` returns one object
with the same row shape:

```jsonc
{
  "current": true,
  "sessionId": "550E8400-E29B-41D4-A716-446655440000",
  "shortId": "abc123",               // optional
  "name": "auth-feature",            // optional
  "displayTitle": "vim Login.swift", // optional
  "label": "agent"                   // optional
}
```

`current` and `sessionId` are required. Other keys are omitted when
unavailable.

`tabs list` returns one row per live terminal session, not one row per GUI tab.
A tab with split terminal panes can produce several rows.

Unprotected sessions are visible to every caller. A protected session is
visible only to its owner. An out-of-tab caller sees unprotected sessions and
every row has `current: false`.

`name` is creation-time session metadata. `tab rename` changes the GUI title
but does not mutate this field.

`displayTitle` is the GUI's current normalized title for the primary terminal
session. It may disappear after a daemon restart until the GUI republishes it.
Do not use it as a `--tab` reference.

### Pane Rows

`panes list --json` returns the calling tab's device panes:

```jsonc
{
  "paneId": "F3A61C00-3F4B-44F0-8898-18544176A338",
  "udid": "A1B2C3D4-E5F6-47A8-9B0C-D1E2F3A4B5C6",
  "state": "rendering",
  "family": "phone",
  "shortId": "phn001",
  "name": "Primary Phone",
  "capabilities": {
    "touch": true,
    "key": true,
    "text": true,
    "button": true,
    "rotate": true,
    "crown": true,
    "accessibility": true,
    "location": true
  },
  "target": {
    "sim": {
      "udid": "A1B2C3D4-E5F6-47A8-9B0C-D1E2F3A4B5C6"
    }
  }
}
```

Required fields:

| Field | Type | Meaning |
|---|---|---|
| `paneId` | string | Pane UUID |
| `udid` | string | Device key for either backend |
| `state` | string | Current pane lifecycle |

Current lifecycle values are:

- `"booting"`
- `"rendering"`
- `"shutdown"`
- `"failed"`

Optional fields:

| Field | Meaning |
|---|---|
| `family` | `"watch"`, `"phone"`, `"pad"`, `"tv"`, `"unknown"`, or a future value |
| `shortId` | Short pane reference |
| `name` | Optional pane name |
| `capabilities` | Per-pane supported operation families |
| `target` | Backend-neutral device discriminator |

A physical-device target uses:

```json
{
  "device": {
    "deviceId": "00008130-001C195E0E91802E"
  }
}
```

A current daemon emits `capabilities` and `target`. Their optional encoding
permits an older daemon to remain decodable during an update.

If `target` is absent, treat the pane as a Simulator for compatibility with
older releases. If a new capability flag is absent from a present capabilities
object, treat that capability as unsupported.

### Device Roster Rows

`devices list --json` returns owned booted Simulators and connected physical
devices:

```jsonc
{
  "id": "00008130-001C195E0E91802E",
  "kind": "device",
  "name": "Development iPhone",
  "model": "iPhone 17 Pro",
  "osVersion": "27.0",
  "state": "connected",
  "attached": true,
  "ownerSessionId": "550E8400-E29B-41D4-A716-446655440000"
}
```

Fields:

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Simulator UDID or physical-device ID |
| `kind` | string | `"sim"` or `"device"` |
| `name` | string, optional | Human-readable device name |
| `model` | string, optional | Physical-device hardware model |
| `osVersion` | string, optional | Physical-device OS version |
| `state` | string, optional | CoreSimulator state or `"connected"` |
| `attached` | boolean | Whether a pane visible to the caller mirrors it |
| `ownerSessionId` | string, optional | Visible owner session |

The roster is not a replacement for `simctl list` or `devicectl list`. It
excludes shutdown and never-booted Simulators, and externally booted Simulators
remain absent until DeviceTerm claims them.

When another caller owns a protected attachment, the entry reports
`attached: false` and omits `ownerSessionId`. This is intentionally
indistinguishable from an unattached device.

### Window Rows

`windows list --json` returns:

```jsonc
[
  {
    "index": 1,
    "isKey": true,
    "tabCount": 3,
    "selectedTabShortId": "abc123"
  }
]
```

`index`, `isKey`, and `tabCount` are required. `selectedTabShortId` is omitted
when unavailable.

Without `--all`, an in-tab caller receives its own window. An out-of-tab caller
receives an empty array.

With `--all`, DeviceTerm returns the caller-visible window projection. Windows
containing only foreign protected tabs are omitted, and indices and counts are
computed after that filtering.

### Tab Information

`tab info --json` returns:

```jsonc
{
  "sessionId": "550E8400-E29B-41D4-A716-446655440000",
  "shortId": "abc123",
  "name": "auth-feature",
  "role": "agent",
  "isCurrent": true,
  "simPanes": [
    {
      "paneId": "F3A61C00-3F4B-44F0-8898-18544176A338",
      "udid": "A1B2C3D4-E5F6-47A8-9B0C-D1E2F3A4B5C6",
      "shortId": "phn001",
      "displayName": "iPhone 17 Pro",
      "family": "phone"
    }
  ]
}
```

Required top-level fields are `sessionId`, `role`, `isCurrent`, and `simPanes`.
The other fields are optional. `cwd` and `label` are reserved optional fields;
the current GUI omits them.

`sessionId`, `shortId`, and `name` describe the GUI tab's primary terminal
session. `isCurrent` is true when the calling terminal belongs to the resolved
tab, including a non-primary split terminal.

`simPanes` contains Simulator panes only. It does not enumerate physical-device
panes. Use `panes list --json` for the backend-neutral pane roster.

### Pane Information

`pane info --json` returns:

```jsonc
{
  "paneId": "F3A61C00-3F4B-44F0-8898-18544176A338",
  "udid": "A1B2C3D4-E5F6-47A8-9B0C-D1E2F3A4B5C6",
  "shortId": "phn001",
  "name": "Primary Phone",
  "displayName": "iPhone 17 Pro",
  "family": "phone",
  "linkedSessionId": "550E8400-E29B-41D4-A716-446655440000"
}
```

`shortId` and `name` are optional. Every other field is required.

`pane info` currently resolves Simulator panes only. Use `panes list --json`
to inspect physical-device panes.

`linkedSessionId` is the primary terminal session of the containing tab.

### Doctor Report

Run:

```sh
deviceterm doctor --json
```

Shape:

```jsonc
{
  "ok": true,
  "checks": [
    {
      "name": "Daemon socket",
      "status": "ok",
      "detail": "/path/to/deviceterm.sock"
    }
  ],
  "session": {
    "sessionId": "550E8400-E29B-41D4-A716-446655440000",
    "shortId": "abc123",
    "name": "auth-feature"
  },
  "targets": [],
  "role": "agent",
  "allowedMethods": [
    "daemon.events",
    "pane.input.tap",
    "panes.list"
  ]
}
```

`ok` and `checks` are always present. `ok` is true when no check has
`status: "fail"`. Warnings do not make the command fail.

Optional fields:

| Field | Presence |
|---|---|
| `session` | Live session identity was resolved |
| `targets` | Session authentication reached `panes.list`; may be an empty array |
| `role` | Live daemon or `DEVICETERM_SESSION_ROLE` environment fallback supplied a role |
| `allowedMethods` | Daemon capabilities query succeeded |

`targets` contains `PanesListEntry` objects from `panes list --json`. It
represents linked device panes, including Simulator and physical-device panes.

Each check has:

```json
{
  "name": "Session authenticates (cap + provenance)",
  "status": "ok",
  "detail": "panes.list accepted"
}
```

Current status values are `"ok"`, `"warn"`, and `"fail"`. Branch on `status`;
display `detail` without parsing it.

Current check names are:

| Name | Meaning |
|---|---|
| `DEVICETERM_SESSION` | Session environment value and UUID shape |
| `DEVICETERM_SESSION_CAP` | Capability environment presence |
| `DEVICETERM_DAEMON_SOCK` | Daemon socket environment path |
| `DEVICETERM_SHIM_DIR` | Per-session shim directory |
| `xcrun resolves to shim` | Whether `xcrun` resolves through the DeviceTerm shim |
| `Daemon socket` | Daemon socket reachability |
| `Daemon ping` | Daemon handshake and wire version |
| `Session live in daemon` | Session appears in `tabs.list` |
| `Session authenticates (cap + provenance)` | Session credentials and terminal provenance authenticate |

Check names and `detail` text are best-effort diagnostics. Pin the DeviceTerm
release if an integration must branch on a check name.

When the daemon socket is unreachable:

- `ok` is false.
- `Daemon socket` has `status: "fail"`.
- `Daemon ping` is absent because the ping is not attempted.
- `allowedMethods` is omitted.
- `session` and `targets` are omitted.
- `role` may still appear from the tab environment.

Treat a role with a failed socket check as the caller's intended role, not
proof that its methods are currently available.

## Action Receipts

A successful action receipt contains `"ok": true`. A failed action prints an
error to stderr, exits nonzero, and emits no success object.

Input receipts identify the resolved pane. Workspace receipts usually echo the
caller's unresolved reference.

### Input Receipts

Every input receipt begins with:

```jsonc
{
  "ok": true,
  "udid": "A1B2C3D4-E5F6-47A8-9B0C-D1E2F3A4B5C6",
  "paneId": "F3A61C00-3F4B-44F0-8898-18544176A338",
  "shortId": "phn001"
}
```

`shortId` is optional. The other fields are required.

Coordinates in a receipt are in the same normalized, displayed space the
command took: `(0,0)` is the top-left of what the device is showing. The
daemon converts to the device's native frame internally and does not report
the converted value.

That conversion follows a Simulator's observed display orientation. A
physical-device pane exposes no orientation source, so it is treated as
portrait until DeviceTerm performs a rotation on it.

The command adds these fields:

| Command | Additional Fields |
|---|---|
| `tap` | `x`, `y` |
| `app-switcher` | `x`, `y`, containing the fixed gesture start at `0.5`, `0.99` |
| `swipe` | `dispatched?`, `steps?`, `durationMs?` |
| `long-press` | `x`, `y`, `durationMs?` |
| `pinch` | `durationMs?` |
| `button` | `button` |
| `key` | `keyCode`, `down` |
| `text` | `bytes` |
| `rotate` | `orientation?`, `direction?` (exactly one) |
| `crown` | `delta`, `velocity?`, `durationMs?` |

A `rotate` receipt carries `orientation` when the command named one, and
`direction` when it named `left` or `right`. The daemon's acknowledgment
doesn't report where the device ended up, so a relative receipt echoes the
direction asked for rather than a resulting orientation.

Example tap receipt:

```json
{
  "ok": true,
  "paneId": "F3A61C00-3F4B-44F0-8898-18544176A338",
  "shortId": "phn001",
  "udid": "A1B2C3D4-E5F6-47A8-9B0C-D1E2F3A4B5C6",
  "x": 0.5,
  "y": 0.5
}
```

Example swipe receipt:

```json
{
  "dispatched": "drag",
  "durationMs": 250,
  "ok": true,
  "paneId": "F3A61C00-3F4B-44F0-8898-18544176A338",
  "shortId": "phn001",
  "steps": 15,
  "udid": "A1B2C3D4-E5F6-47A8-9B0C-D1E2F3A4B5C6"
}
```

`dispatched` is `"tap"` when a sub-frame swipe collapses to a tap-shaped
dispatch, or `"drag"` when interpolation occurs. The three swipe
acknowledgment fields may all be absent when a newer CLI talks to an older
daemon.

`keyCode` is a hexadecimal string such as `"0x30"`. `orientation` uses
camel-case wire values such as `"landscapeLeft"` even though CLI input accepts
kebab-case.

`text.bytes` reports the UTF-8 byte count and never echoes the typed content.
`crown.velocity` echoes a supplied value even though the daemon currently
ignores that option; the key is omitted when the option is absent.

An input receipt confirms that the daemon completed its dispatch call. It does
not confirm that the target application handled the input or that the screen
changed.

### Workspace Receipts

Workspace receipts echo the requested tab, pane, or window reference.
`"current"` remains `"current"`.

| Command | Success Shape |
|---|---|
| `tab open` | `{ok, window}` |
| `tab close` | `{ok, tab, mode}` |
| `tab rename` | `{ok, tab, name?}` |
| `tab select` | `{ok, tab}` |
| `tab move` | `{ok, tab, toIndex?, toWindow?}` |
| `pane open --terminal` | `{ok, tab}` |
| `pane close` | `{ok, pane, mode}` |
| `device attach` | `{ok, target, kind}` |
| `window open` | `{ok}` |
| `window close` | `{ok, window, mode}` |
| `window focus` | `{ok, window}` |
| `tab send-input` | `{ok, tab, bytes, typeDelayMillis?}` |
| `tab set-protected` | `{ok, tab, isProtected, committed}` |

Optional destination or name keys are omitted when the corresponding option is
absent.

Example tab move:

```json
{
  "ok": true,
  "tab": "abc123",
  "toIndex": 1,
  "toWindow": "2"
}
```

Example device attachment:

```json
{
  "kind": "device",
  "ok": true,
  "target": "00008130-001C195E0E91802E"
}
```

The attachment receipt confirms that the GUI accepted the attachment request.
It does not include the new `paneId` or confirm that a display stream is
rendering. Observe `panes list --json` or `events` when readiness matters.

`tab open` does not return the new session ID. `pane open --terminal` does not
return the new terminal session ID, and `window open` does not return a window
identifier.

### Unsupported Workspace Verbs

`pane rename` and `pane move` are present in the command catalog but are not
implemented. They fail with `intent.internalError`.

Do not decode or depend on the dormant `PaneRename` or `PaneMove` receipt
structs. No public success shape exists for these commands.

## Accessibility

Accessibility commands always emit JSON and require session scope. They
support Simulator panes only; see the physical-device limits in
[`USAGE.md`](USAGE.md#know-the-physical-device-limits).

### Apple Node Dictionaries

DeviceTerm wraps each accessibility result under a command-specific top-level
key. Read an `ax tree` node through `.tree` and an `ax point` node through
`.element`. `ax sweep` also uses `.tree` because its synthetic root has the
same recursive shape as an accessibility tree.

`ax tree` returns:

```jsonc
{
  "tree": {
    "role": "Button",
    "label": "Continue",
    "identifier": "continue-button",
    "subrole": "AXCloseButton",
    "value": "Continue",
    "frame": {
      "x": 20,
      "y": 80,
      "w": 120,
      "h": 44
    },
    "children": []
  }
}
```

`ax point` returns one node without a `children` array:

```jsonc
{
  "element": {
    "role": "Button",
    "label": "Continue",
    "frame": {
      "x": 20,
      "y": 80,
      "w": 120,
      "h": 44
    }
  }
}
```

The top-level `tree` and `element` keys are DeviceTerm-owned and
stable-additive. Current nested node fields are:

- `role`
- `label`, optional
- `identifier`, optional
- `subrole`, optional
- `value`, optional
- `frame` with `x`, `y`, `w`, and `h`
- `children` on tree nodes

These dictionaries derive from private Apple accessibility frameworks. Their
roles, values, nesting, availability, and field behavior are best-effort. Do
not treat the nested node schema as a DeviceTerm-owned compatibility contract.

On watchOS, `ax tree` can return an empty `children` array even when elements
are visible. The object under `tree` may include a diagnostic `note` directing
you to `ax sweep` or `ax point`.

### Sweep Wrapper

`ax sweep` samples the screen with point queries, removes duplicate elements,
and returns a DeviceTerm-owned wrapper:

```json
{
  "tree": {
    "role": "AXSweepRoot",
    "frame": {
      "x": 0,
      "y": 0,
      "w": 1,
      "h": 1
    },
    "children": [],
    "step": 0.04,
    "sweepedPoints": 625
  }
}
```

The synthetic object under `tree` has these stable-additive fields:

| Field | Type | Meaning |
|---|---|---|
| `role` | string | Always `"AXSweepRoot"` |
| `frame` | object | Normalized full-screen frame |
| `children` | array | Unique Apple accessibility nodes |
| `step` | number | Clamped step used by the sweep |
| `sweepedPoints` | integer | Number of sampled grid points |

The objects inside `children` remain best-effort Apple node dictionaries.

A successful empty `children` array means the bridge responded but the sweep
found no unique elements. A systemic bridge failure exits nonzero and prints an
error instead of returning a successful empty wrapper.

## Automation

### Hold a Live Grant

Seven commands require a live automation grant, checked for each request:
`tab open`, `tab select`, `tab move`, `window open`, `window focus`,
`tab send-input`, and `tab capture`. A caller without one receives
`error.scope_violation`, including a caller whose environment still says its
role is `"automation"`.

Five more commands are authorized per target rather than by scope:
`tab close`, `window close`, `tab rename`, `pane open --terminal`, and
`pane close`. They stay session-scoped, so `daemon.capabilities` keeps
advertising them; the GUI checks the resolved target and refuses there. A
refusal arrives as daemon error `-32011`, the same code the scope check
returns, with a message beginning `intent.automationRequired`.

Two requirements, and the difference matters. `tab rename`,
`pane open --terminal`, and `pane close` need **ownership**: a terminal of
yours in the target tab. `tab close` and `window close` need **sole-terminal
ownership**, meaning you hold the tab's only terminal, and for a window
every tab in it must satisfy that. A live automation grant satisfies either
one.

Only the GUI issues a grant, and the CLI cannot grant authority to itself.
The grant lifecycle is described in
[`AUTOMATION.md`](AUTOMATION.md#open-an-automation-tab).

### Send Input

Run:

```sh
deviceterm tab send-input --tab abc123 'make test\n' --json
```

Receipt:

```json
{
  "bytes": 10,
  "ok": true,
  "tab": "abc123"
}
```

With paced typing:

```json
{
  "bytes": 10,
  "ok": true,
  "tab": "abc123",
  "typeDelayMillis": 40
}
```

The receipt reports UTF-8 bytes and never includes the text.

A successful receipt means DeviceTerm dispatched instant input synchronously.
For a positive `typeDelayMillis`, it means paced typing was enqueued and may
still be running. Neither result confirms that the target shell executed the
command.

Concurrent paced calls to the same tab are typed in order. The CLI caps
`typeDelayMillis` at 1000.

### Capture a Viewport

Run:

```sh
deviceterm tab capture --tab abc123 --json
```

Shape:

```json
{
  "text": "visible terminal contents\n"
}
```

The capture contains the currently visible terminal viewport. It does not
include scrollback.

The JSON string preserves the captured content. DeviceTerm adds only the
newline that terminates the outer JSON document.

### Set Protection

Run:

```sh
deviceterm tab set-protected true --json
```

Confirmed result:

```json
{
  "committed": true,
  "isProtected": true,
  "ok": true,
  "tab": "current"
}
```

Unconfirmed result:

```json
{
  "committed": false,
  "isProtected": true,
  "ok": true,
  "tab": "current"
}
```

`committed: true` means the daemon confirmed the requested state.
`committed: false` means the transition remains unconfirmed and the GUI may
still be converging.

A definite rejection is a command failure, not a receipt with
`committed: false`.

Protection behavior, including what other callers can no longer see or do, is
described in [`AUTOMATION.md`](AUTOMATION.md#protect-a-tab).

### Run a Child With a Pane Target

`with-pane` resolves a device pane, sets `DEVICETERM_TARGET_PANE` to that pane's
device key, and runs the child with inherited standard streams:

```sh
deviceterm with-pane phn001 sh -c \
  'deviceterm tap 0.5 0.5 --json'
```

`with-pane` emits no receipt of its own. The child's stdout and stderr pass
through unchanged.

The wrapper returns the child's exit status. If a signal terminates the child,
it returns `128 + signal`; a spawn failure returns 127.

## Events

`deviceterm events` subscribes to the current session's event stream. It emits
one JSON object per line until the session closes, the daemon exits, the
connection fails, or the process is terminated.

Output is always JSON Lines:

```sh
deviceterm events \
  | jq --unbuffered 'select(.type == "pane.stateChanged")'
```

Recipes that combine the stream with state polling, and the
subscribe-before-triggering rule they follow, are in
[`AUTOMATION.md`](AUTOMATION.md#wait-on-events).

### Event Shape

Every event has `type` and `ts`. Per-type optional fields are omitted when
unused:

```json
{
  "paneId": "F3A61C00-3F4B-44F0-8898-18544176A338",
  "state": "rendering",
  "ts": "2026-08-08T15:30:12.123Z",
  "type": "pane.stateChanged",
  "udid": "A1B2C3D4-E5F6-47A8-9B0C-D1E2F3A4B5C6"
}
```

`ts` is an ISO 8601 UTC timestamp.

Current event types are:

| `type` | Additional Fields | Meaning |
|---|---|---|
| `pane.stateChanged` | `paneId`, `udid`, `state` | Pane entered `booting`, `rendering`, `shutdown`, or `failed` |
| `device.booted` | `udid` | Simulator boot was observed |
| `device.shutdown` | `udid` | Simulator shutdown was observed |
| `session.created` | `sessionId`, `shortId`, `name?` | Session became live |
| `session.closed` | `sessionId` | Session closed |

For `pane.stateChanged`, `udid` is the pane's target key. It can therefore
contain a Simulator UDID or physical-device ID.

New event types may be added compatibly. Ignore unknown `type` and `state`
values.

### Delivery and Ordering

A subscription receives events in the order the daemon's event broker
publishes them. Publishers serialize through the broker, and each subscriber
receives that order through its stream buffer.

The broker does not retry delivery. Device lifecycle sources are debounced
where they report the same observed transition, but integrations should still
make state changes idempotent instead of treating the stream as a transaction
log.

A slow consumer does not block publishers. The daemon uses an unbounded
in-memory stream buffer, so consumers should continue draining the stream
rather than leaving it unread.

### Loss and Restart Behavior

The stream has no replay or durable journal, and the CLI emits no public
readiness record. Events published before a subscription is established are
not delivered later.

Events can be lost when:

- the subscriber is not yet connected;
- the `deviceterm events` process exits or is killed;
- the daemon restarts;
- the session closes; or
- the socket connection fails.

A daemon restart closes the stream, and the CLI exits successfully on EOF.
Events published during the restart window are unavailable.

Use list commands as the source of current truth. Use events as a low-latency
notification that tells you when to refresh that state.

### Scope and Privacy

The stream requires an authenticated, live DeviceTerm tab session.

A session-scoped subscriber receives:

- `pane.stateChanged` for its tab's device panes;
- its own `session.closed` as the final session event;
- its own session lifecycle events when they occur after subscription; and
- every Simulator `device.booted` and `device.shutdown` event.

A CLI subscriber normally cannot observe its own `session.created` event
because the session exists before its shell can start the subscription. It
never receives another session's private lifecycle events.

The validated GUI uses a separate privileged subscription and can observe
every session. CLI callers cannot request that scope.

### Events Not Included

`pane.surfaceChanged` is not part of `deviceterm events`. Surface rotation
belongs to the GUI's private per-pane rendering subscription.

`device.booted` and `device.shutdown` include no device name, runtime, or
model. For an owned or attached Simulator, refresh `devices list --json` or
`panes list --json` when you need metadata. An external, unclaimed Simulator
can emit either event while remaining absent from both lists; use
`xcrun simctl list devices --json` as the fallback metadata source for its
UDID.

`session.closed` includes no close mode. The GUI does not publish whether the
tab detached or shut down its Simulators.

`session.created.name` is the optional creation-time session name. `tab rename`
changes the GUI title and does not mutate that field.
