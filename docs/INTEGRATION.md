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
deviceterm pane list --json
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
    "message": "intent.automationRequired: pane rename needs a live automation grant for this target; run it from an Automation Tab",
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
| `intent.notFound` | No caller-visible workspace object matched the reference |
| `intent.ambiguous` | More than one caller-visible object matched within a resolution tier |
| `intent.guiUnavailable` | The GUI back-channel was absent or missed its deadline |
| `intent.userCancelled` | The person cancelled a GUI confirmation |
| `intent.automationRequired` | The resolved target requires ownership the caller lacks or a live grant |
| `intent.wouldCloseTab` | Closing the selected terminal would remove the tab's final terminal |
| `intent.unsupportedPane` | The selected pane kind does not support the requested operation |
| `intent.mutationFailed` | A compound mutation partially committed; inspect `error.details.committed` |
| `intent.internalError` | A DeviceTerm invariant failed after the request reached the GUI |

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
| `WorkspaceWindow.id` | Stable UUID for one live GUI window |
| `WorkspaceTab.id` | Stable UUID for one live tab workspace |
| `WorkspacePane.id` | Stable UUID for one layout leaf; for a terminal it equals `sessionId` |
| Window or tab `shortId` | First six lowercase hexadecimal characters of the object's UUID |
| Pane `shortId` | Six lowercase Crockford base32 characters minted for the session or device pane |
| `name` | Optional user-assigned stable name. Matching is case-insensitive and exact; duplicates are ambiguous |
| `WorkspaceWindow.index` | One-based display-order metadata after visibility filtering; never a reference |
| `WorkspaceTab.title` | Normalized GUI title, capped at 256 UTF-8 bytes. It is display metadata, not an identifier |
| `WorkspacePane.terminal.title` | Normalized per-pane label, capped the same way. Also display metadata, and distinct from its tab's |
| `udid` in a Simulator pane | Lowercase Simulator UDID |
| `deviceId` in a physical-device pane | CoreDevice device ID |
| `id` in the device roster | A Simulator UDID (lowercase) or physical CoreDevice device ID |

A Simulator UDID is a case-insensitive UUID, and case is where two outputs stop
comparing equal. DeviceTerm prints a *resolved* one lowercase: `pane list`,
`pane show`, `tab show`, `devices list`, input receipts, and the event stream.
`simctl` prints the same UDID uppercase, and physical device IDs keep the
uppercase form `devicectl` reports.

References resolve case-insensitively, so once a Simulator is attached, its
uppercase UDID from `simctl list devices` works as a `--pane` argument. Case
matters only when comparing strings from different tools.

Workspace refs are raw strings. A window or tab accepts an exact short ID,
exact full UUID, exact unique name, or unique full-UUID prefix. A pane accepts
an exact short ID, exact full ID, exact unique name, exact Simulator UDID or
physical device ID, or unique full-ID prefix. Names never match by prefix.
Window indices are output metadata only.

An omitted ref or `current` selects the object containing the calling
terminal. For a pane, that means the calling terminal pane, not the pane most
recently focused in the GUI. Workspace receipts carry resolved, committed
objects and never echo an unresolved `"current"` or `"abc123"` token.

Rename grammar is deliberately bounded. `tab rename [<tab>] <name>` and
`pane rename [<pane>] <name>` accept one positional argument for the current
object or two for an explicit target. Quote a name containing spaces. A word
beginning with `-` is read as a flag, so put `--` before it to use it literally.
More than two positionals is a usage error. Pass a quoted empty string to clear
the name.

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
GUI issues a grant; see
[`AUTOMATION.md`](AUTOMATION.md#understand-tabs-sessions-and-authority).

Protected tabs remain opaque to other callers. Lists omit protected tabs and
their panes unless the caller owns that protected tab.

## Surface Matrix

| Command | Machine Output | Scope | Completion Meaning | Stability |
|---|---|---|---|---|
| `window list --json` | Array of workspace window rows | Session | Current GUI projection | Stable-additive |
| `window show --json` | Window detail object | Session | Current GUI projection | Stable-additive |
| `tab list --json` | Array of tab workspace rows | Session | Current GUI projection | Stable-additive |
| `tab show --json` | Tab, panes, and layout | Session | Current GUI projection | Stable-additive |
| `pane list --json` | Array of every pane kind | Session | Current GUI projection in layout order | Stable-additive |
| `pane show --json` | One terminal, Simulator, or device pane | Session | Current GUI projection | Stable-additive |
| `session show --json` | Session report | Daemon-wide | Report returned for the calling connection | Stable-additive |
| `devices list --json` | Array of device roster rows | Session | Current owned-Simulator and connected-device snapshot | Stable-additive |
| `doctor --json` | Doctor report | None required; session fields are conditional | Checks completed | Stable-additive except diagnostic prose |
| `version --json` | Version report | Local, with optional daemon probe | Local report completed | Stable-additive |
| `dump-config --json` | Configuration report | Local | Configuration file parsed | Stable-additive |
| `tap`, `swipe`, `app-switcher`, `long-press`, `pinch` with `--json` | Input receipt | Session | Daemon completed the input dispatch call | Stable-additive |
| `button`, `key`, `text`, `crown` with `--json` | Input receipt | Session | Daemon completed the input dispatch call | Stable-additive |
| `rotate` with `--json` | Input receipt | Session | Requested orientation confirmed | Stable-additive |
| `wait pane <state>` with `--json` | Wait receipt | Session | Named pane state observed before the deadline | Stable-additive |
| `wait ax` with `--json` | Wait receipt | Session | The requested accessibility condition, present or absent, observed before the deadline | Stable-additive |
| `wait orientation <orientation>` with `--json` | Wait receipt | Session | Confirmed orientation and stable surface observed before the deadline | Stable-additive |
| `wait surface quiescent` with `--json` | Wait receipt | Session | Rendered surface unchanged for the settle window before the deadline | Stable-additive |
| `tab rename` with `--json` | Workspace receipt | Session and tab ownership, or automation | GUI returned success for the requested mutation | Stable-additive |
| `tab close` with `--json` | Workspace receipt | Session and sole-terminal tab ownership, or automation | GUI returned success for the requested mutation | Stable-additive |
| `tab open`, `tab focus`, `tab move` with `--json` | Workspace receipt | Automation | GUI returned success for the requested mutation | Stable-additive |
| `pane split` with `--json` | Workspace receipt | Session and target-tab ownership, or automation | GUI committed the terminal split | Stable-additive |
| `pane close`, `pane rename` with `--json` | Workspace receipt | Exact target-session ownership for a terminal; target-tab ownership for a Simulator or device; or automation | GUI committed the mutation | Stable-additive |
| `device attach --json` | Workspace receipt | Session | GUI committed pane attachment; rendering may still be pending | Stable-additive |
| `window close` with `--json` | Workspace receipt | Session and sole-terminal ownership of every tab in the window, or automation | GUI returned success for the requested mutation | Stable-additive |
| `window open`, `window focus` with `--json` | Workspace receipt | Automation | GUI returned success for the requested mutation | Stable-additive |
| `tab protect`, `tab unprotect` with `--json` | Workspace receipt | Session and tab ownership, or automation | GUI committed the protection state | Stable-additive |
| `pane focus --json` | Workspace receipt | Automation | GUI committed focus across window, tab, and pane | Stable-additive |
| `pane send-input --json` | Workspace receipt | Automation | Input was dispatched or paced typing was enqueued | Stable-additive |
| `pane capture-text --json` | `{pane, text}` | Automation | Visible terminal viewport captured; `--ansi` keeps SGR sequences | Stable-additive |
| `ax tree`, `ax point` | DeviceTerm wrapper containing an Apple accessibility node | Session | Accessibility query completed | Stable-additive wrapper and `normalizedCenter`; best-effort Apple fields |
| `ax sweep` | DeviceTerm sweep wrapper containing Apple nodes | Session | Sweep stopped, having finished the grid or spent its budget | Stable-additive wrapper and child `normalizedCenter`; best-effort Apple fields |
| `events` | JSON Lines stream | Session | Subscription remains active until EOF or termination | Stable-additive |
| `with-pane` | Child-owned stdout and stderr | Session | Child process exited | Stable exit forwarding |
| `help`, `agents` | Prose | Local, with optional daemon discovery | Documentation printed | Not a JSON contract |
| `completions install` | Prose and a written completion file | Local | Completion file installed | Not a JSON contract |

`tab show`, `pane list`, and `pane show` remain session-scoped commands. The
optional `terminal.cwd` field has a narrower rule: an external caller receives
it only while its session holds a live automation grant. No other field carries
that rule. `terminal.title` and `terminal.tty` reach every session-scoped
caller.

## Discovery and State

### Session Report

Run:

```sh
deviceterm session show --json
```

Shape:

```jsonc
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "role": "automation",
  "automationGrant": true
}
```

`automationGrant` is always present and always a boolean. It is the authority.
`role` is descriptive metadata and can read `"automation"` while the grant is
absent, so never branch on it.

`id` and `role` are omitted for a caller outside a DeviceTerm tab. That is a
successful report with `automationGrant: false`, not a refusal.

An unreachable daemon is a different state: the command fails with
`transport.unavailable` or `transport.timeout` and a nonzero exit, and emits no
`automationGrant` key. Do not read a missing daemon as a missing grant; they
call for opposite responses.

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

### Tab Rows and Details

`tab list --json` returns one row for each real GUI tab workspace. By
default it lists the calling terminal's window. `--window <ref>` selects one
window; `--all` spans the caller-visible workspace.

```jsonc
{
  "id": "11111111-1111-1111-1111-111111111111",
  "shortId": "111111",
  "name": "auth-feature",
  "title": "vim Login.swift",
  "windowId": "22222222-2222-2222-2222-222222222222",
  "current": true,
  "selected": true,
  "protected": false,
  "state": "ready",
  "paneCount": 3
}
```

All fields except `name` are required. `state` is `"opening"`,
`"ready"`, or `"failed"`. `current` means the calling terminal belongs to
the tab. `selected` means the tab is selected in its host window; these are
distinct for a selected tab in another visible window.

A tab ref accepts its exact `shortId`, exact full `id`, exact unique `name`,
or a unique full-ID prefix. Name prefixes and the dynamic `title` are not
references.

`tab show <ref> --json` returns the row, its panes in layout order, and
the recursive split layout:

```jsonc
{
  "tab": { "...": "WorkspaceTab" },
  "panes": [
    { "...": "WorkspacePane" }
  ],
  "layout": {
    "type": "split",
    "axis": "horizontal",
    "extents": [0.5, 0.5],
    "children": [
      {"type": "pane", "paneId": "550e8400-e29b-41d4-a716-446655440000"},
      {"type": "pane", "paneId": "f3a61c00-3f4b-44f0-8898-18544176a338"}
    ]
  }
}
```

`layout` is optional for a tab without a usable pane tree. A pane leaf is
`{type: "pane", paneId}`. A split node is
`{type: "split", axis, extents, children}`, where `axis` is
`"horizontal"` or `"vertical"`.

An empty `tab list` result is a successful caller-visible projection. A
protected tab is visible only to its owning sessions. Each GUI tab produces one
row, regardless of how many terminal splits it contains.

### Pane Rows and Details

`pane list --json` returns every terminal, Simulator, and physical-device
pane in layout order. It defaults to the calling terminal's tab;
`--tab <ref>` selects another visible tab, and `--all` spans every
caller-visible tab in every window. Passing both is a usage error.

`--all` orders panes by window, then tab, then layout. It widens the listing
and not the visibility rule: a protected tab the caller does not own stays out
of it, exactly as it does from `tab list --all`.

Terminal pane:

```jsonc
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "shortId": "term01",
  "name": "test runner",
  "kind": "terminal",
  "tabId": "11111111-1111-1111-1111-111111111111",
  "tabTitle": "vim Login.swift",
  "windowId": "22222222-2222-2222-2222-222222222222",
  "current": true,
  "focused": true,
  "capabilities": ["sendInput", "captureText"],
  "terminal": {
    "sessionId": "550e8400-e29b-41d4-a716-446655440000",
    "title": "vim Login.swift",
    "tty": "/dev/ttys004",
    "cwd": "/Users/example/project"
  }
}
```

#### Terminal Title

`terminal.title` is the pane's own label. Every row a current GUI projects
carries it. It resolves to the first of these that survives normalization: the
OSC 0/2 title the running program set, the pane's `name`, the basename of the
shell's OSC 7 directory, then `"shell"`. Normalization caps it at 256 UTF-8
bytes and strips control and bidirectional-override characters, the same
treatment `WorkspaceTab.title` gets.

The field can be absent during an interrupted update. `--json` relays the GUI's
bytes unchanged, so a CLI from a newer bundle paired with a GUI from an older
one emits terminal rows with no `title` until DeviceTerm restarts. Compare
`daemon` against `rpcWire` in `deviceterm version` to recognize that state, and
read a missing `title` as version skew rather than as a normal row.

Each terminal in a split tab reports its own. Use it rather than the tab's
title to label a pane: `WorkspaceTab.title` describes the tab, and a tab whose
focused pane is a Simulator takes that pane's name instead.

`pane rename` writes `name`, which ranks below the OSC title, so a renamed pane
running a program keeps reporting the program. The tab label treats the same
rename the same way. Read `name` for what the user called the pane and `title`
for what it is doing now.

#### Terminal TTY

`terminal.tty` is the pane's controlling terminal device as a full path, such
as `/dev/ttys004`.

An absent `tty` means terminal identity is temporarily unavailable, commonly
before the shell spawns or after the surface detaches. It never means DeviceTerm
cannot report one. A terminal becomes addressable as soon as `tab open` or
`pane split` commits session creation, which is before its surface attaches, so
an early read after creating a pane may omit it. Retry rather than treating it
as unsupported.

Any session-scoped caller receives it. Unlike `cwd`, it needs no automation
grant.

#### Terminal Working Directory

`terminal.cwd` is an optional live process snapshot. It appears in terminal
rows returned by `pane show`, `pane list`, and `tab show` only when the caller
holds a live automation grant. Owning the terminal does not provide an
exemption; an ungranted read still succeeds but omits the field.

DeviceTerm derives fresh anchor facts from the terminal's current foreground
identity for every projection. If that identity cannot be verified, it omits
`cwd`. After successful derivation, it reports the working directory of a
verified same-user process associated with the terminal. The resolver may use
an unambiguous same-user shell if the foreground candidate becomes unusable. A
nested interactive shell therefore reports its own directory; after it exits,
the outer shell's directory returns.

Treat the value as a snapshot. A foreground command that changes its own
directory can temporarily replace the shell's value, and a process handoff can
leave the field absent for one read.

DeviceTerm also omits `cwd` when the surface is unavailable, process metadata
cannot be read, or the terminal identity changes during the read. When fallback
must select among the session leader's children, more than one qualifying child
also causes omission. The enclosing workspace command still succeeds. It never
substitutes the startup directory or the shell's OSC 7 title state.

Simulator pane:

```jsonc
{
  "id": "f3a61c00-3f4b-44f0-8898-18544176a338",
  "shortId": "phn001",
  "kind": "simulator",
  "tabId": "11111111-1111-1111-1111-111111111111",
  "current": false,
  "focused": false,
  "capabilities": ["touch", "key", "text", "button", "rotate", "accessibility"],
  "simulator": {
    "udid": "a1b2c3d4-e5f6-47a8-9b0c-d1e2f3a4b5c6",
    "displayName": "iPhone 17 Pro",
    "family": "phone",
    "state": "rendering",
    "orientation": "portrait",
    "pixelWidth": 1206,
    "pixelHeight": 2622,
    "capabilities": {
      "touch": true,
      "key": true,
      "text": true,
      "button": true,
      "rotate": true,
      "crown": false,
      "accessibility": true,
      "location": true
    }
  }
}
```

A physical-device pane has `kind: "device"` and a `device` object with
the same display, state, orientation, pixel, and backend capability fields,
plus `deviceId` instead of `udid`.

#### Pane Tab Context

Every pane row carries `tabTitle` and `windowId` beside `tabId`, so listing the
workspace needs no second call to name or group the tabs.

`tabTitle` describes the tab, not the pane. A tab whose focused pane is a
Simulator takes that pane's name, so a terminal row's `tabTitle` can name
something other than that terminal. `terminal.title` is the pane's own label.

Both are empty strings when the enclosing object cannot be resolved, which is
how `tabId` already reports that state. Both can also be absent from raw JSON
during an interrupted update, for the reason given under
[Terminal Title](#terminal-title).

The common fields `id`, `shortId`, `kind`, `tabId`, `current`,
`focused`, and `capabilities` are required; `name` is optional. Exactly
one of `terminal`, `simulator`, or `device` is present according to
`kind`. `tabTitle` and `windowId` are required on every row.
Current workspace capabilities are `sendInput`, `captureText`,
`touch`, `key`, `text`, `button`, `rotate`, `crown`,
`accessibility`, and `location`. Integrations should branch on the list
rather than infer support from `kind`.

Inside `terminal`, `sessionId` and `title` are present on every row a current
GUI projects; `tty` and `cwd` are optional.

A terminal pane's `id` is its `sessionId`. That identity is available as
soon as `tab open` or `pane split` commits session creation; it does not
mean the shell surface has attached yet.

`pane show <ref> --json` returns the same `WorkspacePane` shape for one
pane. A pane ref accepts an exact `shortId`, exact full `id`, exact unique
`name`, exact Simulator UDID or physical device ID, or unique full-ID prefix.

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

### Window Rows and Details

`window list --json` returns the calling terminal's window. `--all` returns
every caller-visible window:

```jsonc
[
  {
    "id": "22222222-2222-2222-2222-222222222222",
    "shortId": "222222",
    "name": "automation",
    "index": 1,
    "current": true,
    "focused": true,
    "selectedTabId": "11111111-1111-1111-1111-111111111111",
    "tabCount": 3
  }
]
```

All fields except `name` and `selectedTabId` are required. `current`
means the calling terminal belongs to this window. `focused` is the GUI's
key-window state. `selectedTabId` is omitted when the window's selected tab is
hidden from the caller; every returned tab then has `selected: false`. A window
ref accepts an exact `shortId`, exact full `id`, exact unique `name`, or unique
full-ID prefix. The one-based `index` is display-order metadata and never
resolves as a ref.

Windows containing only foreign protected tabs are omitted. Indices and counts
are computed after visibility filtering, so hidden tabs do not leak through
gaps or totals.

`window show <ref> --json` returns `{window, tabs}` using the same
`WorkspaceWindow` and `WorkspaceTab` shapes.

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
    "pane.deviceList"
  ]
}
```

`ok` and `checks` are always present. `ok` is true when no check has
`status: "fail"`. Warnings do not make the command fail.

Optional fields:

| Field | Presence |
|---|---|
| `session` | Live session identity was resolved |
| `targets` | Session authentication reached internal `pane.deviceList`; may be an empty array |
| `role` | Live daemon or `DEVICETERM_SESSION_ROLE` environment fallback supplied a role |
| `allowedMethods` | Daemon capabilities query succeeded |

`targets` contains daemon-direct `PanesListEntry` objects from the internal
`pane.deviceList` check. It represents linked device panes, including
Simulator and physical-device panes; it is not the public `pane list` shape.

Each check has:

```json
{
  "name": "Session authenticates (cap + provenance)",
  "status": "ok",
  "detail": "pane.deviceList accepted"
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
| `Session live in daemon` | The daemon accepts the session identity |
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

Input receipts identify the resolved pane. Workspace receipts contain the
resolved objects committed by the GUI and never echo an unresolved reference.

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
| `tap` | `x`, `y`; a selector-driven tap adds `role?`, `label?`, `identifier?`, `matchCount?`, `elapsedMs?` |
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

Workspace mutations return `WorkspaceMutationReceipt` objects built from the
GUI state after the mutation commits:

```jsonc
{
  "ok": true,
  "window": { "...": "WorkspaceWindow" },
  "tab": { "...": "WorkspaceTab" },
  "pane": { "...": "WorkspacePane" }
}
```

The object contains only fields relevant to the mutation:

| Command | Committed fields |
|---|---|
| `window open` | `window`, first `tab`, initial terminal `pane` |
| `window focus` | `window`, selected `tab`, focused `pane` |
| `window close` | `closed.resource == "window"`, `closed.window`, `mode` |
| `tab open` | host `window`, new `tab`, initial terminal `pane` |
| `tab focus` | `window`, `tab` |
| `tab move` | destination `window`, moved `tab` |
| `tab rename`, `tab protect`, `tab unprotect` | `tab` |
| `tab close` | `closed.resource == "tab"`, `closed.tab`, `mode` |
| `pane split` | host `tab`, new terminal `pane` |
| `pane focus` | `window`, `tab`, `pane` |
| `pane rename` | `pane` |
| `pane close` | `closed.resource == "pane"`, `closed.pane`, `mode` |
| `device attach` | host `tab`, attached `pane` |
| `pane send-input` | `pane`, `bytes`, optional `typeDelayMs` |

`device attach` returns a receipt only after the GUI commits a
`WorkspacePane`. A pending or failed placeholder has no public pane ID and
does not appear in `pane list` or `tab show`.

If attachment fails, the placeholder remains visible and the CLI returns the
daemon's typed error. For example, daemon code `-32000` becomes
`rpc.serverError`, with `details.rpcCode` set to `-32000`. Repeat the same
`device attach` command to retry the placeholder in its existing layout slot.
A successful retry returns the host `tab` and committed `pane`; rendering may
still be pending.

Refs in receipts are canonical committed objects. The CLI does not echo an
input such as `"current"` or a short ref and ask the caller to rediscover what
it meant.

Open and split receipts wait for terminal session creation. A terminal pane's
`id` and `terminal.sessionId` are therefore available in the success
response. They do not assert that the shell surface is attached or ready for
input.

A tab can commit before its initial terminal session fails. That outcome is a
typed failure rather than a success receipt:

```jsonc
{
  "error": {
    "code": "intent.mutationFailed",
    "message": "terminal session creation failed",
    "details": {
      "committed": {
        "ok": true,
        "window": { "...": "WorkspaceWindow" },
        "tab": {
          "state": "failed"
        }
      }
    }
  }
}
```

The failed tab remains visible and addressable. Branch on the error code and
retain `error.details.committed.tab.id`.

An explicit `pane close --mode` is valid only after the pane ref resolves to a
Simulator. Supplying it for a terminal or physical-device pane fails with
`intent.unsupportedPane`. Omitting the option closes those pane kinds normally
and resolves a Simulator close to `detach`. Closing a tab or window may still
take `--mode` because either can contain linked Simulators.

`pane capture-text --json` is a read result rather than a mutation receipt:

```jsonc
{
  "pane": { "...": "WorkspacePane" },
  "text": "visible terminal contents\n"
}
```

Human mode prints the captured text directly. The capture is the visible
viewport only.

`--ansi` keeps the viewport's SGR color and style sequences in the same
`text` field. ESC has no shorthand JSON escape, so it arrives as `\u001b`.

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
because it matches every string-valued identifier or label. An empty `--value`
under `--match contains` is a usage error for the same reason.

`--state` chooses which way the query is read. The default `present` waits for
a match and reports the condition `ax.appears`. `absent` waits for the query to
match nothing, reports `ax.disappears`, and carries `matchCount` 0 in the
observation:

```sh
deviceterm wait ax --label "Saving..." --match contains --state absent
```

An absent wait will not conclude from an observation that did not see
everything, because the element could be in the part that went unseen. A
truncated sweep returns `wait.inconclusive` at once, and an unsupported tree
walk returns `wait.unsupported`. An incomplete tree is retried, and returns
`wait.inconclusive` only if no complete observation arrives before the
deadline. An element still matching at the deadline returns `wait.timeout`, since
a sighting settles the question whatever else the observation missed.

`--state absent` cannot be combined with `--print center`. There is no element
left to take a coordinate from, and succeeding with empty stdout would be
indistinguishable from a refusal.

`--role` is always exact and case-sensitive, in both modes. A role names a
fixed vocabulary rather than app-authored text.

`--value` is a filter, not a selector. It ANDs onto `--identifier` or
`--label` and compares under the same `--match` mode, because a value carries
the same counts and ellipses a label does. A non-string value never matches:
the comparison is textual.

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
deadline. What a truncated sweep means then depends on what you asked for.

A plain `wait ax` asks whether an element is present, and a match answers that
whatever went unseen, so it succeeds.

Nothing matching is a claim about everything the observation covered, so the
failure reports the observation rather than the deadline. A truncated sweep
with no match returns `wait.inconclusive` on the probe that saw it. A tree the
daemon noted as incomplete is retried instead: if the deadline arrives with no
match and the last observation still carried the note, the wait returns
`wait.inconclusive` in place of `wait.timeout`. A match on a still-noted tree
succeeds, because presence needs no more coverage than the sighting.

That substitution needs an observation this wait actually reached. A probe that
dies in one of its own requests produces none, so the wait reports the deadline
rather than a verdict drawn from an earlier probe.

`--print center` and `tap` do not select from an incomplete observation, even
when the visible matches contain one eligible target. Anything the observation
missed could add another target, reveal the real control behind a caption, or
change the containment result.

A tree marked `ax.treeIncomplete` is retried. If no complete observation
arrives before the deadline, the command returns `wait.inconclusive`.
Unsupported enumeration and a truncated sweep refuse immediately. None of
these outcomes prints a coordinate or dispatches a tap.

In every case the message is the daemon's own note, and `details` carries
`note` and `noteCode`, plus `sweepedPoints`, `step`, and `budgetMs` when a
sweep raised it, so a caller can tell a sweep worth retrying with a larger
budget from one already at the ceiling.

A tree observation that comes back empty on watchOS returns `wait.unsupported`,
carrying the same two fields. The refusal follows the daemon's note rather than
the pane's device family, so it costs one accessibility probe, and a watch pane
whose tree does enumerate is a legitimate match instead of a refusal.

The observation contains `source`, `matches`, and `matchCount`. `matches` holds
the matched elements, up to 20 of them; `matchCount` is how many there were in
total. A control and the caption inside it often share a label, so more than
one match is ordinary rather than a caller error.

`matchesTruncated` is present and `true` only when the list was trimmed.
Without it a caller has to compare `matchCount` against a cap it can only read
here.

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
obscured, or behind a modal, and `matches[0]` is not guaranteed to carry a
`normalizedCenter`.

To act on a match, don't pick from the list. Two commands make the same
selection:

```sh
deviceterm wait ax --label Continue --match contains --print center
deviceterm tap --label Continue --match contains
```

`--print center` writes a bare `<x> <y>` and nothing else, ready to pass as a
coordinate verb's two positional arguments. `tap` with the same selector taps
that element directly, so no coordinate crosses the shell.

### Selecting a Coordinate Target

Selection discards every match that is presentational or carries no
`normalizedCenter`. A centreless element supplies no ready coordinate, and a
presentational one is excluded so a caption never stands in for the control
wrapping it, even though a caption often carries a perfectly good centre. If
what
remains nests, it takes the innermost, which is the control rather than the
container holding it.

Nesting is frame containment, not position in the walk. `ax sweep` returns
every element as a sibling of a synthetic root, so a structural test would call
every multi-match sweep disjoint.

If the survivors do not nest, the wait refuses with `wait.ambiguous` rather
than choosing. Two unrelated controls matching one query is a query that named
two things. Narrow it with `--role`, `--value`, or `--identifier`.

If nothing survives, the wait refuses with `wait.unreachable`.

Both exit 1 and carry `matchCount` and the distinct `roles` observed, which is
usually enough to see that a caption matched and the control did not.

What a refusal writes depends on the caller. Under `--print center` it writes
nothing to stdout, so one piped onward supplies no coordinate. Under
`tap --json` it writes the standard error envelope, so test the exit code
rather than stdout emptiness.

Selection is geometric: it needs the survivors to form a containment chain,
and refuses when they do not, whatever the cause. A selected element is
reachable by coordinate rather than proven operable, because the observation
cannot say whether it is enabled or obscured.

`tap --label` and `tap --identifier` run this same selection over the same
wait, so the element `--print center` names is the element `tap` hits. A
refusal ends the command before any input is dispatched. `wait.unreachable`,
`wait.ambiguous`, `wait.inconclusive`, `wait.unsupported`, and `wait.timeout`
send no tap.

`--print center` cannot be combined with `--json`, which is a usage error.
`--json` promises stdout is a JSON document and `--print` promises a bare
coordinate, and the two also disagree on failure, where `--json` writes an
error envelope to stdout and `--print` writes nothing.

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

### Surface Conditions

Run:

```sh
deviceterm wait surface quiescent --settle 800
```

The observation contains `surface` (`sequence`, `width`, `height`) and the
`settleMs` the wait was given. `--settle` defaults to 500 and accepts 0, which
asks for two agreeing observations rather than a window.

Quiescence is the surface being *unchanged*, never advanced by a given amount.
A Simulator increments `sequence` once per frame; a physical device reports
lease generations that jump. Nothing portable can be read from the size of a
step, so only equality is tested. Width and height join `sequence` in that
test, so a resize inside the window restarts it.

A pane carrying no `surface` is an unmet condition rather than a quiescent
one. Nothing drawn is not the same as nothing moving, and `wait pane rendering`
is what waits for a first frame.

This is not a rotation signal. Surface dimensions do not swap when a device
turns, so a rotation can complete without either dimension changing; use
`wait orientation`.

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

`tap`, `swipe`, `long-press`, `pinch`, and `ax point` refuse a coordinate
outside the inclusive 0 through 1 range, along with a non-numeric, NaN, or
infinite one. The refusal is `cli.invalidUsage`, exits 1, and happens before
any daemon round-trip.

The range matches `normalizedCenter`, so every centre the daemon emits is
accepted by the verbs above.

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

`ax point` and `ax sweep` also hand back the frame they used, as `rootFrame`:

```json
"rootFrame": {"x": 0, "y": 0, "w": 400, "h": 800}
```

Multiply a `normalizedCenter` by `rootFrame.w` and `rootFrame.h` to get
displayed points back.

When present, it appears once per response, at the top of the `ax point`
element and on the `ax sweep` root, and never on a nested child. `ax tree`
doesn't carry it, because its own root `frame` is already the scale.

`rootFrame` is omitted when the preflight root had no usable frame, and on a
sweep that expired before its preflight. There is no placeholder,
since a synthesized 1x1 frame would be indistinguishable from a real 1x1
screen.

Don't read its absence as "this response has no centres". An unscalable root
omits both, but a root with usable dimensions and an unusable origin can still
produce `normalizedCenter` for usable nodes while `rootFrame` stays absent.
Check for each field on its own.

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
    },
    "rootFrame": {
      "x": 0,
      "y": 0,
      "w": 400,
      "h": 800
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

With the exception of `normalizedCenter` and `rootFrame`, these dictionaries
derive from private Apple accessibility frameworks. Their roles, values,
nesting, availability, and field behavior are best-effort. Both exceptions are
DeviceTerm-owned stable-additive fields even though they appear inside the
node.

`rootFrame` is absent from the list above because it isn't a nested node field.
It appears once, on the top-level `ax point` element and on the `ax sweep`
root, and on no child.

On watchOS, `ax tree` can return an empty `children` array even when elements
are visible. The object under `tree` may include a diagnostic `note` directing
you to `ax sweep` or `ax point`, alongside a `noteCode` naming it.

Both fields are DeviceTerm-owned and stable-additive, and they carry the same
meanings here as in the sweep wrapper below. Branch on `noteCode`, which
survives a rewording of the sentence; show `note`.

`ax tree` can also return a tree that reads as complete and is not. The
daemon hit-tests one point the walk left uncovered and may set `note`, with
`noteCode` `ax.treeIncomplete`, when that point holds an element the tree
does not carry. A web view is one known case: `ax tree`
returns the browser's chrome and nothing from the page, while `ax sweep`
reaches the content.

Do not use an empty `children` array as the signal. This note can accompany
a populated tree, and an empty tree on a non-watch pane can earn it too.
Read `noteCode` whatever `children` holds.

The note reports what a hit-test found, never why the walk stopped, so do
not read a cause into it. It also under-reports: one point is sampled, a
finding the daemon cannot confirm against a second read is dropped, and an
element missing from an unannotated tree is still not proof the element is
off screen.

The daemon carries one note at a time. On watchOS the empty-walk note above
wins.

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
    "rootFrame": {
      "x": 0,
      "y": 0,
      "w": 400,
      "h": 800
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
| `frame` | object | Normalized placeholder, always `0, 0, 1, 1`; not the screen's frame, which is `rootFrame` |
| `rootFrame` | object | The preflight screen frame in displayed points; omitted unless the preflight yielded a finite origin and positive finite dimensions |
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
`normalizedCenter` remains a successful partial result. `rootFrame` runs the
other way: it belongs to the root alone and appears on no child.

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
true with `sweepedPoints` zero without querying the bridge at all, and carries
no `rootFrame`, since nothing measured the screen. That result says nothing
about whether accessibility is reachable. Retry it when the pane is quieter.

## Automation

### Hold a Live Grant

Eight commands require a live automation grant, checked for every request:
`tab open`, `tab focus`, `tab move`, `window open`,
`window focus`, `pane focus`, `pane send-input`, and
`pane capture-text`. A caller without one is refused at the daemon
connection, before the request reaches the GUI, with `session.unauthorized`,
including a caller whose environment role is still `"automation"`.

Owner-scoped verbs are checked in the GUI instead. `window close`,
`tab close`, `tab rename`, `tab protect`, `tab unprotect`, `pane split`,
`pane close`, and `pane rename` return `intent.automationRequired` when an
ungranted caller does not satisfy the target's ownership requirement, spelled
out below. A caller that satisfies it proceeds without a grant. Both codes
carry `rpcCode` -32011, so the code tells you which layer refused.

Owner-contained mutations remain session-scoped. `tab rename` and `pane split`
require the caller to own a terminal in the target tab. For `pane rename` and
`pane close`, a terminal target must be the caller's exact session; Simulator
and physical-device targets retain tab ownership. `tab close` and `window
close` require sole-terminal ownership because they may end other sessions. A
live automation grant satisfies these target checks.

`tab protect` and `tab unprotect` require target-tab ownership or a live grant.
A grant can protect a visible, unprotected foreign tab. It never exposes a
foreign protected tab, so it cannot unprotect one from outside.

Only the signature-validated GUI issues grants. There is no CLI grant or revoke
command and no public `automation.revoke` RPC. Session removal, issuing-GUI
disconnect, and other lifecycle transitions revoke authority internally.

### Send Input

Run:

```sh
deviceterm pane send-input term123 'make test\n' --json
```

Receipt:

```jsonc
{
  "ok": true,
  "pane": { "...": "terminal WorkspacePane" },
  "bytes": 10
}
```

A paced call also includes `typeDelayMs`:

```jsonc
{
  "ok": true,
  "pane": { "...": "terminal WorkspacePane" },
  "bytes": 10,
  "typeDelayMs": 40
}
```

The command requires an explicit terminal pane ref. The receipt reports UTF-8
bytes and never includes the text. Instant input is dispatched synchronously;
positive pacing is enqueued and may still be running when the receipt arrives.
Neither result confirms that the target shell executed the command. The CLI
caps `typeDelayMs` at 1000.

Escapes are decoded by the CLI before the text reaches the daemon, and only
the recognized sequences: an unknown escape like `\z` and a trailing backslash
are left as written. Pass `--raw` to decode nothing, which is what a caller
forwarding arbitrary strings wants, since a `\n` it meant literally becomes a
newline rather than an error.

`--raw` governs escape decoding only. The trailing words join with single
spaces either way, so quote text whose spacing matters.

### Capture a Viewport

Run:

```sh
deviceterm pane capture-text term123 --json
```

Shape:

```jsonc
{
  "pane": { "...": "terminal WorkspacePane" },
  "text": "visible terminal contents\n"
}
```

The capture contains the terminal pane's currently visible viewport and not
its scrollback. Human mode writes the text directly.

Run:

```sh
deviceterm pane capture-text term123 --ansi --json
```

Shape:

```jsonc
{
  "pane": { "...": "terminal WorkspacePane" },
  "text": "\u001b[0m\u001b[1m\u001b[38;5;1mred\u001b[0m plain\n"
}
```

The sequences are rebuilt from each cell's style, not echoed back from what
the program wrote. A run opens with a reset, then one sequence per attribute,
and closes with a reset, so a program that wrote `\u001b[1;31m` reads back as
`\u001b[0m\u001b[1m\u001b[38;5;1m`.

Rows are `\n`-separated in both formats. Palette colors are emitted as
palette indexes (`38;5;n`) so the consumer applies its own theme; direct RGB
passes through as `38;2;r;g;b`.

The styled capture is not the plain capture with escapes inserted. A
trailing cell holding a background but no character arrives as a space, which
the plain capture omits. Interior ones become spaces in both, because a later
character on the row flushes them. Strip the escape sequences and trim trailing spaces on each
row and the two match. Row counts always match, because row blankness is
decided from characters alone. A row that is entirely background with no
text is dropped from both, so a colored region survives only on a row
holding at least one character.

Use the plain capture to classify output and the styled one to display it.

### Set Protection

Protect or unprotect a tab:

```sh
deviceterm tab protect abc123 --json
deviceterm tab unprotect abc123 --json
```

Each returns a workspace mutation receipt whose `tab.protected` value is the
committed state. A definite daemon refusal, indeterminate transition, or
superseding mutation is a command failure rather than an optimistic receipt.

Both directions require a terminal owned by the caller in the target tab or a
live automation grant. An ungranted caller targeting a visible tab it does not
own receives `intent.automationRequired`. A grant never widens visibility, so
a foreign protected tab still fails earlier as `intent.notFound`.

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
`pane list --json` when you need metadata. An external, unclaimed Simulator
can emit either event while remaining absent from both lists; use
`xcrun simctl list devices --json` as the fallback metadata source for its
UDID.

`session.closed` includes no close mode. The GUI does not publish whether the
tab detached or shut down its Simulators.

`session.created.name` is the optional creation-time session name. `tab rename`
changes the GUI title and does not mutate that field.
