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
- [Waiting for State](#waiting-for-state)
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

Successful JSON goes to stdout with a trailing newline.

When a JSON-capable, non-streaming command reports a typed failure, stdout
contains a newline-terminated error envelope:

```json
{
  "error": {
    "code": "pane.notFound",
    "message": "no device pane in this tab"
  }
}
```

The `error` object has these fields:

| Field | Stability | Meaning |
|---|---|---|
| `code` | Stable | Dotted identifier intended for programmatic branching |
| `message` | Best-effort | Human-readable diagnostic; do not parse it |
| `details` | Stable-additive, optional | Structured context for the failure |

Daemon failures include their numeric RPC code when available:

```json
{
  "error": {
    "code": "intent.automationRequired",
    "message": "intent.automationRequired: tab.send-input requires automation authority",
    "details": {
      "rpcCode": -32011
    }
  }
}
```

Current shared codes are:

| Code | Meaning |
|---|---|
| `cli.invalidUsage` | The command invocation is malformed |
| `cli.internalError` | The CLI could not encode or process its own result |
| `session.required` | The command requires DeviceTerm tab context |
| `session.unauthorized` | Session authentication or authority was refused |
| `session.notReady` | The session exists but is not ready for the request |
| `transport.unavailable` | The CLI could not connect to the daemon |
| `transport.timeout` | The daemon did not answer before the request deadline |
| `transport.interrupted` | An established daemon connection was interrupted |
| `protocol.invalidResponse` | The daemon response could not be framed or decoded |
| `pane.notFound` | No accessible pane matched the reference |
| `pane.ambiguous` | More than one accessible pane matched the reference |
| `pane.unavailable` | The resolved pane cannot currently perform the request |
| `pane.bridgeFailed` | The pane's device bridge failed |
| `input.refused` | A backend refused a valid input operation |
| `rotate.unconfirmed` | The requested rotation target was not confirmed |
| `rotate.confirmationUnsupported` | The command or backend cannot provide rotation confirmation |
| `wait.timeout` | The wait's overall deadline expired |
| `wait.inconclusive` | The observation completed without enough coverage to decide |
| `wait.unsupported` | The selected pane or observation source cannot observe the condition |
| `rpc.invalidRequest` | The daemon rejected the RPC request shape |
| `rpc.methodNotFound` | The daemon does not implement the requested RPC method |
| `rpc.invalidParams` | The daemon rejected the RPC parameters |
| `rpc.serverError` | The daemon reported an internal server failure |
| `rpc.error` | The daemon returned an otherwise unclassified RPC error |

An `intent.*` code supplied by the daemon passes through unchanged. Commands
may define additional dotted codes for their own outcomes; those codes are
documented with the command.

The CLI preserves its human-readable stderr diagnostic and nonzero exit status
when it emits an error envelope. Branch on `error.code`, not on the message or
stderr text:

```sh
if report=$(deviceterm tap 0.5 0.5 --json); then
  printf '%s\n' "$report" | jq '.'
else
  status=$?
  if code=$(printf '%s\n' "$report" | jq -er '.error.code'); then
    case "$code" in
      pane.notFound)
        printf 'no accessible pane yet\n' >&2
        ;;
      transport.*|session.notReady)
        printf 'DeviceTerm infrastructure is unavailable\n' >&2
        ;;
      *)
        printf 'deviceterm failed: %s\n' "$code" >&2
        ;;
    esac
  else
    printf 'deviceterm returned an untyped failure\n' >&2
  fi
  exit "$status"
fi
```

The shared typed paths currently cover usage, session context, transport,
response decoding, pane resolution, and daemon errors. Command-specific
failure paths that have not adopted the typed primitive still emit no JSON
envelope. Check the exit status before decoding stdout, and treat empty stdout
after failure as an untyped failure.

`events` retains its JSON Lines streaming behavior and human-readable stream
errors. `with-pane` continues to inherit its child process's stdout, stderr,
and exit behavior.

Most command, usage, transport, and daemon failures exit with status 1.
Special cases are:

| Command | Exit Behavior |
|---|---|
| `doctor` | 0 when no check has `status: "fail"`; otherwise 1 |
| `events` | 0 when the daemon closes the stream normally |
| `wait` | 124 only when the overall deadline becomes `wait.timeout`; other failures use 1 |
| `with-pane` | Child exit status, or `128 + signal` when signaled |
| `with-pane` spawn failure | 127 |

A failing `doctor --json` still returns its doctor report rather than an error
envelope. Its exit status indicates whether any check failed.

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
details, and Apple-sourced accessibility fields are best-effort.
`normalizedCenter` is DeviceTerm-owned even though it appears inside an
accessibility node.

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
| `tabId` | Required grouping UUID. GUI terminal sessions share their tab UUID; other sessions use `sessionId`. A GUI-backed value is stable for the open tab's lifetime and accepted by `--tab` |
| `sessionId` | Daemon session UUID. Each terminal session has one, so a split tab can have several |
| `paneId` | UUID for one device pane |
| `shortId` | Short display and reference handle. Optional during version skew |
| `name` | Optional human-assigned or creation-time name. It may be absent or ambiguous |
| `displayTitle` | Live GUI title. It is display metadata, not an identifier |
| `udid` in a pane | The pane's device key: a Simulator UDID (lowercase) or physical CoreDevice device ID |
| `id` in the device roster | A Simulator UDID (lowercase) or physical CoreDevice device ID |

A Simulator UDID is a case-insensitive UUID, and case is where two outputs stop
comparing equal. DeviceTerm prints a *resolved* one lowercase: `panes list`,
`pane info`, `tab info`, `devices list`, input receipts, and the event stream.
`simctl` prints the same UDID uppercase, and physical device IDs keep the
uppercase form `devicectl` reports.

A receipt that echoes an unresolved reference is the exception. `device attach`
on an externally booted Simulator has no roster entry to resolve against, so it
prints back the spelling you gave it.

References resolve case-insensitively, so once a Simulator is attached, its
uppercase UDID from `simctl list devices` works as a `--pane` argument. Case
matters only when you compare strings, and only when one side came from outside
DeviceTerm.

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
| `button`, `key`, `text`, `crown` with `--json` | Input receipt | Session | Daemon completed the input dispatch call | Stable-additive |
| `rotate` with `--json` | Input receipt | Session | Requested orientation confirmed | Stable-additive |
| `wait pane <state>` with `--json` | Wait receipt | Session | Named pane state observed before the deadline | Stable-additive |
| `wait ax` with `--json` | Wait receipt | Session | Matching accessibility element observed before the deadline | Stable-additive |
| `wait orientation <orientation>` with `--json` | Wait receipt | Session | Confirmed orientation and stable surface observed before the deadline | Stable-additive |
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
| `ax tree`, `ax point` | DeviceTerm wrapper containing an Apple accessibility node | Session | Accessibility query completed | Stable-additive wrapper and `normalizedCenter`; best-effort Apple fields |
| `ax sweep` | DeviceTerm sweep wrapper containing Apple nodes | Session | Sweep stopped, having finished the grid or spent its budget | Stable-additive wrapper and child `normalizedCenter`; best-effort Apple fields |
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
  "tabId": "11111111-1111-1111-1111-111111111111",
  "sessionId": "550E8400-E29B-41D4-A716-446655440000",
  "shortId": "abc123",               // optional
  "name": "auth-feature",            // optional
  "displayTitle": "vim Login.swift", // optional
  "label": "agent"                   // optional
}
```

`current`, `tabId`, and `sessionId` are required. Other keys are omitted when
unavailable.

`tabs list` returns one row per live daemon session. Each GUI terminal pane has
a session, so a split tab produces multiple rows with one shared `tabId`.
Sessions without a GUI tab self-group under `sessionId`.

Group rows and count visible session groups without follow-up calls:

```sh
rows=$(deviceterm tabs list --json) || exit $?

printf '%s\n' "$rows" | jq 'sort_by(.tabId) | group_by(.tabId)'
printf '%s\n' "$rows" | jq 'map(.tabId) | unique | length'
```

GUI-backed groups correspond to tabs, and their full `tabId` can be passed
directly to `--tab`. The response does not distinguish non-GUI groups, so the
distinct count is not always a GUI-tab count.

Successful discovery always emits one newline-terminated JSON document. `[]`
with exit 0 means no daemon sessions are visible to this caller. A failure
exits nonzero and emits the shared `{"error": ...}` envelope, so it cannot be
mistaken for an empty workspace. A response that cannot be decoded, omits
required `tabId`, or contains a malformed `tabId` fails with
`protocol.invalidResponse`.

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
  "udid": "a1b2c3d4-e5f6-47a8-9b0c-d1e2f3a4b5c6",
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
      "udid": "a1b2c3d4-e5f6-47a8-9b0c-d1e2f3a4b5c6"
    }
  }
}
```

Required fields:

| Field | Type | Meaning |
|---|---|---|
| `paneId` | string | Pane UUID |
| `udid` | string | Device key for either backend. Simulator UDIDs are lowercase |
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
| `capabilities` | Per-pane device capabilities; see below for what each flag gates |
| `target` | Backend-neutral device discriminator |
| `orientationConfirmationSupported` | Whether the backend can produce confirmed orientation evidence; absent for version skew |
| `orientation` | Latest confirmed orientation; absent until confirmation is available |
| `surface` | Current `{sequence, width, height}` surface metadata; absent before a surface exists |

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

Seven flags gate a CLI verb family: `touch`, `key`, `text`, `button`, `rotate`,
`crown`, and `accessibility`. `location` is the exception, and `location: true`
does not mean you can set a position from the CLI.

What it gates is a GUI affordance: the Location submenu, in the Device menu and
in a device pane's context menu. `pane.location.*` is GUI-only, and `location`
is on the CLI's no-simctl-wrappers list, so there is deliberately no verb behind
it.

`touch` carries an exception of its own. On a physical device it covers `tap`,
`swipe`, `long-press`, and `app-switcher` but not `pinch`, which is refused
whatever `touch` reports. A Simulator supports all five.

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
      "udid": "a1b2c3d4-e5f6-47a8-9b0c-d1e2f3a4b5c6",
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
  "udid": "a1b2c3d4-e5f6-47a8-9b0c-d1e2f3a4b5c6",
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

A successful action receipt contains `"ok": true`. A failed action never emits
a success object. In JSON mode, typed failures follow the error-envelope
contract above; command-specific failure paths that have not adopted it remain
stderr-only.

Input receipts identify the resolved pane. Workspace receipts usually echo the
caller's unresolved reference.

### Input Receipts

Every input receipt begins with:

```jsonc
{
  "ok": true,
  "udid": "a1b2c3d4-e5f6-47a8-9b0c-d1e2f3a4b5c6",
  "paneId": "F3A61C00-3F4B-44F0-8898-18544176A338",
  "shortId": "phn001"
}
```

`shortId` is optional. The other fields are required.

Coordinates in a receipt are in the same normalized, displayed space the
command took: `(0,0)` is the top-left of what the device is showing. The
daemon converts to the device's native frame internally and does not report
the converted value.

That conversion follows a Simulator's observed display orientation. A physical
device has no passive orientation source, so its pane starts in portrait and
updates when a DeviceTerm rotation result includes an observed orientation.

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
| `rotate` | `orientation?`, `direction?` (exactly one), `targetOrientation`, `observedOrientation` |
| `crown` | `delta`, `velocity?`, `durationMs?` |

A `rotate` receipt carries `orientation` when the command named one, and
`direction` when it named `left` or `right`. `targetOrientation` is the
absolute target DeviceTerm resolved, and `observedOrientation` is the
orientation that confirmed it. Both are required on success.

Example relative rotate receipt:

```json
{
  "direction": "left",
  "observedOrientation": "landscapeLeft",
  "ok": true,
  "paneId": "F3A61C00-3F4B-44F0-8898-18544176A338",
  "shortId": "phn001",
  "targetOrientation": "landscapeLeft",
  "udid": "a1b2c3d4-e5f6-47a8-9b0c-d1e2f3a4b5c6"
}
```

On a Simulator, confirmation is the display observation that also drives
rendering and coordinate mapping. A relative request starts from the latest
confirmed display orientation. DeviceTerm waits up to four seconds for the
target; an orientation-locked app that leaves the display unchanged fails
instead of producing a receipt. At most two rotations may be outstanding on a
pane; another request fails immediately as `rotate.unconfirmed` without
dispatch, and may be retried after a slot opens.

On a physical device, `left` and `right` go directly to the relay. The reply
supplies the absolute orientation where the device landed. An absolute request
uses the same replies to converge on its target. A physical device turned by
hand remains invisible until a DeviceTerm rotation returns another orientation.

Rotate can fail with these outcomes. All exit with status 1:

| Code | Meaning | Retryable |
|---|---|---|
| `rotate.unconfirmed` | The per-pane queue was full, the confirmation deadline expired, or the backend reported a different final orientation | Yes, after a queue slot opens or after checking whether the app permits rotation |
| `rotate.confirmationUnsupported` | The daemon or backend cannot supply confirmation | No without changing or upgrading that component |
| `input.refused` | The pane's backend rejects rotation support | No until device capability changes |
| `pane.unavailable` | The pane disappeared or lost its live backend | Yes after restoring or reattaching the pane |
| `session.unauthorized` | Session authority was revoked | No for the current authority |

`rotate.unconfirmed` details may contain `requestedOrientation` or
`requestedDirection`, `targetOrientation`, `observedOrientation`, `deadlineMs`,
and `reason`.

`reason` is `queueFull` when two rotations are already outstanding for the
pane. The daemon did not dispatch the request. Retry after one finishes. Other
`rotate.unconfirmed` outcomes omit `reason`.

Example tap receipt:

```json
{
  "ok": true,
  "paneId": "F3A61C00-3F4B-44F0-8898-18544176A338",
  "shortId": "phn001",
  "udid": "a1b2c3d4-e5f6-47a8-9b0c-d1e2f3a4b5c6",
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
  "udid": "a1b2c3d4-e5f6-47a8-9b0c-d1e2f3a4b5c6"
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
changed. Rotate is the exception: its receipt additionally confirms the
orientation observation described above.

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
rendering. Use `deviceterm wait pane rendering` when readiness matters. The
event stream remains available for long-running observation and low-latency
refresh signals.

`tab open` does not return the new session ID. `pane open --terminal` does not
return the new terminal session ID, and `window open` does not return a window
identifier.

### Unsupported Workspace Verbs

`pane rename` and `pane move` are present in the command catalog but are not
implemented. They fail with `intent.internalError`.

Do not decode or depend on the dormant `PaneRename` or `PaneMove` receipt
structs. No public success shape exists for these commands.

## Waiting for State

`wait` is a non-streaming CLI operation. It probes current state until the
condition holds or its monotonic deadline expires. The default deadline is
30000 milliseconds and `--timeout <ms>` must be positive.

### Wait Receipt

Successful waits produce:

```json
{
  "attempts": 3,
  "condition": "pane.rendering",
  "elapsedMs": 200,
  "observation": {
    "state": "rendering"
  },
  "ok": true,
  "pane": {
    "paneId": "F3A61C00-3F4B-44F0-8898-18544176A338",
    "shortId": "phn001",
    "udid": "a1b2c3d4-e5f6-47a8-9b0c-d1e2f3a4b5c6"
  }
}
```

`ok`, `condition`, `elapsedMs`, `attempts`, `pane`, and `observation` are
required. `pane.shortId` is optional. Observation fields depend on the
condition and are stable-additive.

A probe that observed the condition reports it even when it returns past the
deadline, so `elapsedMs` can exceed `timeoutMs`. The alternative is reporting a
timeout for a condition that was seen to hold.

### Pane Conditions

Run:

```sh
deviceterm wait pane rendering --pane phn001 --timeout 30000
```

Accepted states are `booting`, `rendering`, `shutdown`, and `failed`. The
observation contains `state`.

An explicit pane reference that has not appeared yet is an unsatisfied
condition, not `pane.notFound`. Once a wait resolves a pane, it pins that pane
ID. If the pane later disappears, the query fails with `pane.notFound`.
Ambiguous resolution fails immediately with `pane.ambiguous`.

### Accessibility Conditions

Run exactly one primary match:

```sh
deviceterm wait ax --identifier save-button
deviceterm wait ax --label Save --role Button
```

Matching is recursive. The default source is `tree`.

`--match` selects how the primary selector compares. `exact` is the default and
requires the whole string. `contains` matches a substring and folds case, which
reaches a control whose label carries an unread count or a truncation ellipsis:

```sh
deviceterm wait ax --label Messages --match contains
```

An empty `--identifier` or `--label` under `--match contains` is a usage error,
because it matches every string-valued identifier or label.

`--role` is always exact and case-sensitive, in both modes. A role names a
fixed vocabulary rather than app-authored text.

The walk finds every match rather than stopping at the first. It is
depth-first, checking each `children` array from first to last, and it descends
into an element that matched, because a control and the caption inside it can
both match. That traversal order is what breaks ranking ties below.

Use `--source sweep` with optional `--step` and `--budget` when tree observation
is unavailable:

```sh
deviceterm wait ax --label Continue --source sweep \
  --step 0.05 --budget 20000
```

For `--source sweep`, the CLI applies the normal `[0, 60000]` sweep-budget
clamp and reduces the result to the milliseconds remaining before the wait
deadline. A matching element succeeds even when the sweep reports `truncated`.
A truncated sweep without a match returns `wait.inconclusive`. Its message is
the daemon's own note, and `details` carries `note` and `noteCode`, so a caller
can tell a sweep worth retrying with a larger budget from one already at the
ceiling.

A tree observation that comes back empty on watchOS returns `wait.unsupported`,
carrying the same two fields. The refusal follows the daemon's note rather than
the pane's device family, so it costs one accessibility probe, and a watch pane
whose tree does enumerate is a legitimate match instead of a refusal.

The observation contains `source`, `matches`, and `matchCount`. `matches` holds
the matched elements, up to 20 of them; `matchCount` is how many there were in
total. A control and the caption inside it often share a label, so more than
one match is ordinary rather than a caller error.

`matches` is ordered so `matches[0]` is the element you are most likely able to
operate. Elements whose role is known to be presentational (`StaticText`,
`Image`) rank last. Elements carrying no `normalizedCenter` rank next to last,
because a caller with no coordinate cannot reach them. Everything else ranks by
ascending frame area, because the most specific node under a point is the
control rather than the container holding it.

The centre test sits below the role test on purpose. A control whose centre
falls off-screen loses its `normalizedCenter` while keeping a valid frame, and
it still has to outrank its own caption.

An unrecognized role ranks as actionable. Demoting whatever is missing from a
known-interactive list would bury real controls whenever Apple's best-effort
role vocabulary shifts.

Elements with no usable frame rank last within their group, and ties keep
depth-first document order.

The ordering is a heuristic. It cannot see whether an element is enabled,
obscured, or behind a modal. To tap, take the first entry carrying a
`normalizedCenter` rather than assuming `matches[0]` has one:

```sh
deviceterm wait ax --label Continue --match contains --json \
  | jq -e 'first(.observation.matches[]
                 | select(.normalizedCenter)).normalizedCenter'
```

Reporting `matchCount` separately is what makes a trimmed list visibly trimmed.
Ranking runs before the cap, so the receipt keeps the 20 highest-ranked
candidates.

Each entry has the same shape as an `ax point` element: an `ax tree` node
without `children`. When present, `normalizedCenter` is ready to pass to `tap`.

### Orientation Conditions

Run:

```sh
deviceterm wait orientation landscape-right
```

The pane must support rotation confirmation, expose the requested confirmed
`orientation`, and have a current `surface`. The condition succeeds only after
two consecutive probes report the requested orientation with the same positive
width and height. The observation contains the orientation and final
`{sequence, width, height}` surface metadata.

A false `orientationConfirmationSupported` returns `wait.unsupported`. When
support is true but `orientation` is absent, the wait continues probing because
a later observer callback or confirmed rotation may populate it. A daemon that
omits both fields is treated as unsupported.

### Failure Classification

The overall deadline returns:

```json
{
  "error": {
    "code": "wait.timeout",
    "message": "wait deadline expired after 30000 ms",
    "details": {
      "attempts": 300,
      "condition": "pane.rendering",
      "elapsedMs": 30000,
      "timeoutMs": 30000
    }
  }
}
```

`wait.timeout` exits 124. Every other wait failure exits 1, including
`wait.inconclusive`, `wait.unsupported`, and `pane.notFound`.

Each probe RPC receives the smaller of the time remaining before the wait
deadline and its normal command-specific RPC ceiling. Authentication, response
reads, and retryable session-readiness delays share that single RPC deadline. A
timeout when the remaining overall time is limiting becomes `wait.timeout`; an
earlier command-specific RPC deadline remains `transport.timeout`. Connection,
authentication, bridge, and response-decoding failures retain their shared
codes and return immediately.

Pane resolution splits three ways. An ambiguous target returns
`pane.ambiguous` on the first probe; waits retry absence, not ambiguity. A
pane that resolved and then disappeared returns `pane.notFound` immediately.

A target that matches nothing keeps probing, because a pane can appear while
you wait. That's what lets `xcrun simctl boot` be followed by a wait on the
pane it creates.

If the last completed probe still finds no match at the deadline, the wait
returns `pane.notFound` with the attempt count in `details`. If the roster
request itself exhausts the deadline, it returns `wait.timeout`, because the
final roster went unread.

The implementation uses an immediate first probe followed by non-overlapping
probes at a 100 ms cadence. The interval is internal rather than a CLI option.

## Accessibility

Accessibility commands always emit JSON and require session scope. They
support Simulator panes only; see the physical-device limits in
[`USAGE.md`](USAGE.md#know-the-physical-device-limits).

### Coordinate Space

`ax point` takes normalized coordinates in displayed space, the same space the
coordinate-bearing input verbs take. `(0,0)` is the top-left of what the device
is showing, whichever way it is turned; the daemon converts to the device's
native frame before querying.

Node `frame` values are in that same displayed space, so they turn with the
device and need no rotation of your own. Keep them for point-size checks such
as the 44pt hit-target guideline.

When the root scale and node geometry are usable, DeviceTerm adds:

```json
"normalizedCenter": {"x": 0.2, "y": 0.1275}
```

Its `x` and `y` are the frame centre in normalized displayed space. Pass them
directly to `tap`, `swipe`, `long-press`, `pinch`, or `ax point`.

The field is omitted when the root lacks a positive finite width or height,
the node lacks a finite origin or positive finite dimensions, or the resulting
centre falls outside the inclusive 0 through 1 range. An older daemon can also
omit it. Omission is a successful result, not an error.

For `ax tree`, the tree root supplies the scale for every node. `ax point` and
`ax sweep` use the real frontmost tree read during their preflight. The
synthetic `AXSweepRoot` frame remains a 0,0,1,1 placeholder and is never used
as the scale.

### Apple Node Dictionaries

DeviceTerm wraps each accessibility result under a command-specific top-level
key. Read an `ax tree` node through `.tree` and an `ax point` node through
`.element`. `ax sweep` also uses `.tree` because its synthetic root has the
same recursive shape as an accessibility tree.

`ax tree` returns:

```jsonc
{
  "tree": {
    "role": "Application",
    "frame": {
      "x": 0,
      "y": 0,
      "w": 400,
      "h": 800
    },
    "normalizedCenter": {
      "x": 0.5,
      "y": 0.5
    },
    "children": [
      {
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
        "normalizedCenter": {
          "x": 0.2,
          "y": 0.1275
        },
        "children": []
      }
    ]
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
    },
    "normalizedCenter": {
      "x": 0.2,
      "y": 0.1275
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
- `normalizedCenter` with normalized `x` and `y`, optional and DeviceTerm-owned
- `children` on tree nodes

With the exception of `normalizedCenter`, these dictionaries derive from
private Apple accessibility frameworks. Their roles, values, nesting,
availability, and field behavior are best-effort. `normalizedCenter` is a
DeviceTerm-owned stable-additive field even though it appears inside the node.

On watchOS, `ax tree` can return an empty `children` array even when elements
are visible. The object under `tree` may include a diagnostic `note` directing
you to `ax sweep` or `ax point`, alongside a `noteCode` naming it.

Both fields are DeviceTerm-owned and stable-additive, and they carry the same
meanings here as in the sweep wrapper below. Branch on `noteCode`, which
survives a rewording of the sentence; show `note`.

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
    "budgetMs": 10000,
    "sweepedPoints": 625,
    "truncated": false
  }
}
```

The synthetic object under `tree` has these stable-additive fields:

| Field | Type | Meaning |
|---|---|---|
| `role` | string | Always `"AXSweepRoot"` |
| `frame` | object | Normalized placeholder, always `0, 0, 1, 1`; not the screen's frame |
| `children` | array | Unique Apple accessibility nodes |
| `step` | number | Clamped step used by the sweep |
| `budgetMs` | integer | Clamped scheduling budget the walk ran under, in ms |
| `sweepedPoints` | integer | Grid points this sweep queried |
| `truncated` | boolean | True when the walk stopped before finishing the grid |
| `note` | string | Present only when `truncated`; one of the `AXTreeNote` values |
| `noteCode` | string | Present whenever `note` is; a short stable token naming it |

`note` is a sentence for a person to read. `noteCode` is the token to branch
on, because the two truncation notes differ only in prose and share one error
code. Compare `noteCode`; show `note`.

The objects inside `children` remain best-effort Apple node dictionaries.
Each usable object receives `normalizedCenter` using the preflight tree's real
frame. The synthetic root itself never receives the field. A missing child
`normalizedCenter` remains a successful partial result.

A successful empty `children` array with `truncated` false means the bridge
responded but the sweep found no unique elements. A systemic bridge failure
exits nonzero and prints an error instead of returning a successful empty
wrapper.

The daemon checks a deadline before the pre-flight probe and before each point
query. The wait for the pane's accessibility queue counts toward it, but an
in-flight bridge call is not interrupted. When a check finds the deadline
expired before the grid is complete, the sweep stops before the next query and
returns what it has with `truncated` true, and `sweepedPoints` counts the cells
queried rather than the grid that was planned. This is a successful
response, so a client that ignores `truncated` reads partial coverage as
complete. An element absent from a truncated sweep is not evidence it is absent
from the screen.

`budgetMs` is how long the daemon may spend scheduling queries. It defaults to
10000 and is held inside `[0, 60000]`; like `step`, the clamp is silent, so read
the echo for what you got. Raising it is the remedy for a truncated sweep. The
0.02 step floor plans 2500 queries, and whether they fit inside the default
budget depends on the host and the device, so read `truncated` rather than
predicting it. A sweep that truncates at the ceiling carries a different `note`,
since raising the budget is no longer open to it.

A sweep whose deadline passed before it reached the queue returns `truncated`
true with `sweepedPoints` zero without querying the bridge at all, so that
result says nothing about whether accessibility is reachable. Retry it when the
pane is quieter.

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

Unprotect through the same command:

```sh
deviceterm tab set-protected false --json
```

Result:

```json
{
  "committed": true,
  "isProtected": false,
  "ok": true,
  "tab": "current"
}
```

A definite rejection is a command failure, not a receipt with
`committed: false`.

Both directions need a terminal of yours in the target tab. A caller without
one gets `intent.ownerRequired` and exit status 1. An automation grant does
not satisfy this, unlike the per-target checks in
[hold a live grant](#hold-a-live-grant). A tab the caller cannot see fails
earlier, in resolution, as `intent.notFound`, which doesn't separate a
protected foreign tab from one that isn't there.

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

Use `deviceterm wait` for one-shot convergence. Recipes for waits and the
separate event-stream role are in
[`AUTOMATION.md`](AUTOMATION.md#wait-for-device-state).

### Event Shape

Every event has `type` and `ts`. Per-type optional fields are omitted when
unused:

```json
{
  "paneId": "F3A61C00-3F4B-44F0-8898-18544176A338",
  "state": "rendering",
  "ts": "2026-08-08T15:30:12.123Z",
  "type": "pane.stateChanged",
  "udid": "a1b2c3d4-e5f6-47a8-9b0c-d1e2f3a4b5c6"
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

The stream has no replay or durable journal. Events published before a
subscription is established are not delivered later. The streaming CLI emits
no subscription-readiness record.

Events can be lost when:

- the subscriber is not yet connected;
- the `deviceterm events` process exits or is killed;
- the daemon restarts;
- the session closes; or
- the socket connection fails.

A daemon restart closes the stream, and the CLI exits successfully on EOF.
Events published during the restart window are unavailable.

Use list commands as the source of current truth. Use `deviceterm wait` when a
script must block until one supported condition holds. Use events as a
low-latency notification that tells a long-running consumer when to refresh
state.

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
