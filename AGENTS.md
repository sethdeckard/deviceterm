# DeviceTerm: Agent Conventions

> DeviceTerm follows SemVer for its release version and public `deviceterm` CLI
> and JSON output. During 0.x, minor releases may make breaking changes; patch
> releases remain compatible. `DaemonProtocolInfo.wireVersion` coordinates the
> bundled app, daemon, CLI, and shim during updates. It is internal and is not a
> separate end-user compatibility contract.

> Internal development conventions for both human contributors and AI agents.
> See `README.md` for end-user context, `docs/PHILOSOPHY.md` for the driving
> principles, `docs/ARCHITECTURE.md` for the source-of-truth system design, and
> `docs/BUILDING.md` for build/sign instructions.

## Project Overview

DeviceTerm is a macOS-native terminal application focused on Apple-platform
developer workflows, where iOS Simulators behave as first-class panes inside
the app window. Booting a sim from inside a DeviceTerm tab attaches a live,
interactive pane onto that sim; a `deviceterm` CLI inside the tab drives input,
accessibility, rotation, and pane management for what `xcrun simctl` doesn't
cover.

The system splits across three processes:

- **`DeviceTerm.app`**: AppKit GUI; windows, tabs, panes, rendering.
- **`deviceterm-daemon`**: embedded helper bundle; owns sims, IPC, and the
  menu bar status item. Lazy-spawned, idle-exits when not needed.
- **`deviceterm-cli`**: short-lived CLI client; symlinked into each tab's
  per-session `bin/` directory.

Plus two single-purpose binaries: **`deviceterm-shim`** (xcrun/simctl wrapper for
boot detection) and **`deviceterm-probe`** (CoreSimulator compatibility probe).

For how it fits together, read `docs/ARCHITECTURE.md` before unfamiliar work.

## Key workflows

The Makefile is the single dev surface. These three commands cover almost
everything an agent (or human) does day to day:

```sh
make build      # swift build (debug)
make test       # unit tests (Swift Testing)
make lint       # swiftlint --strict
```

Before pushing, run the gate:

```sh
make verify     # lint + commit-hook smoke + every test layer that has landed
```

`verify` self-skips any check whose backing code is absent. Run `make help` for
the full target list, or see `docs/BUILDING.md` for end-to-end build, signing,
and release instructions.

## Driving Philosophy

The design answers to seven principles, spelled out in `docs/PHILOSOPHY.md`. The
short form, for daily orientation:

1. **The tab is the workspace.**
2. **DeviceTerm owns what it boots; everything else is borrowed.**
3. **Don't reimplement Apple's tools.**
4. **Config is minimal and optional.**
5. **Agents speak CLI.**
6. **The private surface is the product.**
7. **Background daemon, foreground discipline.**

If a PR moves against one of these, the description should call it out so
reviewers can decide whether the trade-off is worth it.

## Code Style

- Every first-party source file opens with
  `// SPDX-License-Identifier: GPL-3.0-or-later`, above the descriptive header
  comment and separated from it by a bare `//`. Shell scripts put the same
  identifier on the line after the shebang. `Package.swift` is the one
  exception to "first line": SwiftPM requires its `swift-tools-version`
  comment to stay at the top, so the identifier goes directly beneath it. The
  SwiftLint `file_header` rule enforces this, so a new Swift file without it
  fails `make lint`. Vendored third-party files keep their upstream notices
  instead and are excluded from the rule.
- Idiomatic Swift; follow Swift API Design Guidelines.
- Swift 6 strict concurrency is on package-wide. New code is `Sendable`-clean.
- Format with SwiftLint's autocorrect-able rules (`swiftlint --fix`). No
  `swift-format` dependency in v1; if needs outgrow SwiftLint's autocorrect,
  revisit in v1.x.
- Hard `line_length` limit of 120 (enforced by SwiftLint). Wrap long lines.
- Owned types (defined in this codebase) declare protocol conformances on the
  **primary type definition**, not in same-file extensions. Extensions exist
  for grouping behavior, not for splitting one type into pieces.
- A *non-conformance* member a shared type cannot host legitimately lives in an
  extension in the owning module, e.g. the daemon-only `bridgeValue` that maps
  a `DaemonProtocol` wire enum (`HardwareButton`/`Orientation`) to a
  CoreSimulatorBridge C enum, which the Foundation-only `DaemonProtocol` must
  never link (`HardwareButton+Bridge.swift`). This is not a conformance, so the
  rule above doesn't apply; add a comment explaining why it's an extension.
- External type conformances live in `Type+Protocol.swift` files (e.g.
  `String+Codable.swift`, `Data+Base64.swift`) so the conformance is
  discoverable from the file name.
- One public *owned* type per file (SHOULD, not a hard rule): a public
  struct/enum gets its own file named for it, so concurrent work doesn't
  collide on "hot files". Tiny, tightly-coupled support types MAY share a
  file when that genuinely reads better.
- Finite wire values are shared `DaemonProtocol` enums, defined once, never
  re-typed as a raw string literal at a call site. The canonical RPC method
  set is `RPCMethod` (`Sources/DaemonProtocol/RPCMethod.swift`); a
  `DaemonTests` drift guard asserts the daemon registry's keys equal its
  cases.
- **GUI type naming**:
  - Presentation/navigation state → **`*ViewModel`** (`@MainActor @Observable
    final class`). Examples: `TabTitleViewModel`, `SimulatorPaneViewModel`,
    `TabListViewModel`, `WorkspaceViewModel`.
  - AppKit view controllers → **`*ViewController`** (drop the legacy `*VC`
    suffix). Examples: `TabStripViewController`, `TabContentViewController`,
    `SimulatorPaneViewController`, `TerminalPaneViewController`,
    `PaneLayoutViewController`.
  - AppKit views → **`*View`** (e.g. `SimulatorContentView`).
  - Window controllers → **`*WindowController`** (e.g. `WindowController`).
  - Navigation = the typed intent **`Route`** + the single dispatcher
    **`Router`**; the AppKit glue reconciles to nav state, never the
    reverse.
  - Pure logic per `*ViewModel` / `*ViewController` lives in reducers
    (`*Reducer`), pure math namespaces, or decision types (`*Decision`).
- Protocol *default* implementations may live in extensions on the protocol.
  That's their natural home.
- Error handling: throw from `async throws` functions; don't swallow errors;
  prefer typed errors at module boundaries.
- No `fatalError` in library code. Daemon `main.swift` and the GUI's
  `AppDelegate` are the only places allowed to terminate the process
  intentionally.

## Commit Messages

- Subject: max 50 chars, capitalized first letter, imperative mood
  (e.g. "Add feature" not "Added feature"), no trailing period.
- Blank line between subject and body.
- Body: wrapped at 72 chars; describe what + *why*, not how.

The `commit-msg` hook in `.githooks/` enforces subject length, capitalization,
no trailing period, blank-line-after-subject, and 72-char body wrap.
Imperative mood is a convention reviewers enforce; the hook can't reliably
validate grammar.

Activate the hook once after cloning:

```
make hooks
```

## Commands

A `Makefile` at repo root is the single entry point for both humans and
agents. Each target **self-skips when its backing thing doesn't exist
yet**: `make daemon` checks `Sources/Daemon/`, `make probe` checks
`Sources/CompatProbe/`, etc. Once the backing source/script lands,
the target runs the real command and fails loudly if it errors. The
filesystem is the truth.

| Target | What it does |
|---|---|
| `make build` | `swift build` (debug) |
| `make bundle` | build the debug `DeviceTerm.app` bundle |
| `make run` | build, stop stale app/daemon processes, and open `DeviceTerm.app` |
| `make kill-daemon` | stop the running app and embedded daemon |
| `make daemon` | build the `deviceterm-daemon` target |
| `make cli` | build `deviceterm-cli` |
| `make shim` | build `deviceterm-shim` |
| `make uitest` | build the out-of-process `deviceterm-uitest` harness |
| `make uitest-run` | bundle and launch the harness, then report its TCC grants |
| `make probe` | build + run `deviceterm-probe` (logs to git-ignored `probe-runs.log`) |
| `make test` | unit tests (Swift Testing) |
| `make test-int` | integration tests (daemon socket, lifecycle, provenance) |
| `make test-shim` | shim+CLI argv/stdio/exit tests |
| `make test-gui` | script-driven GUI smoke test; included in `make verify` |
| `make test-live` | live-sim track (`CoreSimulatorLiveTests`): clean-slate boot + HID/AX/display/booted-owned checks; **shuts down your sims** |
| `make test-device-live` | live physical-device track; never reboots or shuts down the device |
| `make test-uitest` | sim-free GUI smoke through the signed UI-test harness |
| `make lint` | `swiftlint lint --strict` (no-ops with no Swift sources) |
| `make verify` | single-command gate; sub-checks self-skip per filesystem |
| `make clean` | `rm -rf .build` |
| `make release` | signed, notarized DMG |
| `make publish` | publish an existing notarized release, cask, and Sparkle appcast |
| `make hooks` | install `.githooks/` (one-time after clone) |

### `make verify` shape

`make verify` runs SwiftLint first, refuses to wait behind another SwiftPM
process using this checkout, and then checks:

- the commit-message hook against known-good and known-bad messages;
- every target documented by `make help` is declared;
- `swift test`, excluding `CoreSimulatorLiveTests` and `DeviceLiveTests`;
- daemon integration tests when their target exists;
- the CoreSimulator compatibility probe;
- the script-driven GUI smoke test;
- shim and CLI tests; and
- an offline release dry-run.

The two live tracks and the TCC-dependent UI-harness track remain deliberate,
separate commands. `make verify` prints their exclusion so they cannot be
mistaken for covered tests.

## Testing

- **Swift Testing is the default** for unit and integration tests.
  `import Testing`, `@Test`, `#expect`, `#require`, parameterized via
  argument arrays, tags/traits for grouping. Reference: [Swift Testing](https://developer.apple.com/documentation/testing).
- **GUI smoke is script-driven.** `scripts/gui-smoke.sh` exercises the debug
  app in the default gate. The separately signed `deviceterm-uitest` harness
  performs pixel and accessibility checks without an Xcode project or
  `XCUIApplication`.

### Naming convention

```swift
@Test
func parsesLayeredGhosttyConfig() { … }

@Test("device-spec resolution", arguments: [
    ("AB12-…", .udid),
    ("iPhone 17 Pro", .uniqueName),
    ("booted", .bootedSentinel),
])
func resolvesDeviceSpec(input: String, expected: ResolutionKind) { … }
```

No `test` prefix; Swift Testing doesn't need it. Descriptive function names.
Parameterized inputs via the table-style argument list.

### Layers

| Layer | Lives in | Examples |
|---|---|---|
| **Unit** | `Tests/<Module>Tests/` | Config parser, RPC framing/decoding, device-spec resolution, session state machine, session restore batching, kVK→HID translation table |
| **Daemon integration** | `Tests/DaemonIntegrationTests/` | Socket bind + accept, request/response round-trip, multi-client multiplexing, lifetime predicate, idle exit, orphan recovery, provenance rejection |
| **Shim + CLI** | `Tests/ShimTests/`, `Tests/CLITests/` | argv parsing, stdio inheritance preservation, exit code passthrough, signal propagation, snapshot diff, JSON wire emission |
| **GUI smoke** | `scripts/gui-smoke.sh` | App launch plus dispatch and reconciliation checks in the default gate |
| **Live simulator** | `Tests/CoreSimulatorLiveTests/` (deliberate track) | HID/AX/display I/O against a *booted* sim; the daemon booted-owned `device.list` contract. Non-hermetic: needs a real sim. |
| **Live device** | `Tests/DeviceLiveTests/` (deliberate track) | Enumeration, frame flow, HID discovery, touch, and detach against connected hardware. |
| **UI harness** | `Tests/DeviceTermUITestTests/`, `scripts/test-uitest.sh` | Sim-free pixel and accessibility checks. Requires Screen Recording, Accessibility, and an unlocked display. |
| **Private-API manual** | `Tests/Manual/` (procedure docs, not automated) | Boot/render/HID/AX against a live sim. Run before release tags. |

`make verify` and `make test` exclude the simulator and physical-device live
tracks. The UI-harness track also stays separate because it depends on TCC
grants and an unlocked display. The hermetic client-construction and error-path
tests in `CoreSimulatorBridgeTests` remain in the default gate.

The live track is a **deliberate, separate command**: `make test-live`
shuts down all sims (clean slate), boots one, waits via `simctl
bootstatus`, runs `CoreSimulatorLiveTests`, then shuts it down. Run it
after changing `CoreSimulatorBridge` or other private-API code: it is
*not* env-gated and never silently no-ops, so the live coverage can't go
missing unnoticed. The shared RPC harness lives in the `DaemonTestSupport`
library target (used by both `DaemonTests` and `CoreSimulatorLiveTests`).

By default the track boots an **iPhone**; `DEVICETERM_LIVE_DEVICE_FAMILY=watch
make test-live` boots a **watch** instead. This is device *selection*, not
run-gating: the track always runs. Tests that are device-family-specific
(the watchOS Digital Crown) are `.enabled(if:)`-gated on the booted
device's family, so they run on the matching track and skip (not fail) on
the other; the script prints which track it's on and how to flip.

`make test-device-live` requires a connected, unlocked, trusted iPhone or iPad
with a working CoreDevice tunnel. It fails when no device is available and
never reboots or shuts down the device. `make test-uitest` runs the separate,
sim-free harness track after its permissions are configured with
`make uitest-run`.

### Fixtures

Test data (Ghostty configs, RPC wire-format samples, shim argv corpora)
lives under `Tests/<Module>Tests/Fixtures/` and is declared in `Package.swift`
via `.process()` resources on the test target. Tests load via
`Bundle.module.url(forResource:withExtension:)`. **No giant string-literal
blobs in test source files.** Reference: [SwiftPM resources](https://developer.apple.com/documentation/packagedescription/resource).

## Modern Swift Defaults

New code follows these project-wide defaults.

### Concurrency: strict mode, actors over locks

- Package-wide strict concurrency.
- All shared mutable daemon state (`DeviceCoordinator`, `SessionManager`,
  `PaneCoordinator`, `RPCServer`'s connection registry) lives behind
  **actors** or explicit serial `DispatchQueue`s. **No ad hoc `NSLock` /
  `os_unfair_lock` for new state.** Where Obj-C bridging requires queue
  isolation, use a documented `DispatchQueue` and a wrapper that gates
  access.
- Every type crossing an actor or task boundary is `Sendable` (or
  `@unchecked Sendable` with a comment explaining the manual invariant).
- Reference: [Swift strict concurrency](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/).

### Reactive state: Observation, not Combine

- SwiftUI-facing state uses **`@Observable`**. No `ObservableObject` /
  `@Published` for new code.
- **GUI presentation/navigation state lives in `@MainActor @Observable`
  view models** (`*ViewModel`), not in the view controller. The view binds
  once with the **`observe { [weak self] in self?.render() }`** helper
  (`Sources/App/Observe.swift`), written **`App.observe { … }`** inside an
  `NSObject` subclass, since `NSObject`'s KVO `observe` shadows the global.
  VC→VM is intent method calls, VM→VC is the automatic re-render. The view
  model holds presentation/daemon state; pure transitions go through a
  reducer (`SimPaneReducer`) and pure geometry through a math namespace
  (`SimGestureMath`), both unit-tested. `render()` must read every observed
  property it cares
  about on each pass: Observation only tracks what was accessed, so an
  early return (or a `??` short-circuit) stops observing the skipped fields.
  The same VM backs a future SwiftUI surface unchanged; `observe()` is the
  AppKit-only adapter. `TabTitleViewModel` is the reference example.
- **Combine is allowed only as an adapter layer**: bridging APIs that
  already expose publishers, wrapping AppKit notifications when no
  Concurrency-shaped alternative exists, or interop with legacy code being
  ported. Combine is not the default state-management or event-bus layer.
- Reference: [Observation](https://developer.apple.com/documentation/observation).

### Async events: `AsyncSequence` everywhere it fits

- Long-lived daemon events, settings reload notifications, RPC subscriptions
  exposed to client code use `AsyncSequence` (`AsyncStream<T>` for daemon-
  internal producers; protocol-typed `any AsyncSequence<T, Error>` for public
  consumers when the producer might change).
- One-shot async work uses `async throws` returning a value. Don't reach for
  `AsyncSequence` for single-result calls.
- Daemon pane-subscription events (`AsyncStream<PaneEvent>` inside the
  daemon, surfaced to the GUI as RPC `evt` frames) are the canonical
  example.

## SwiftUI / AppKit boundary

**SwiftUI is the default for product UI**: preferences, onboarding, empty
states, error/info banners, inspector-style side panels, simple sheets,
status/detail views, the About panel, and anything else whose shape is
"render state, dispatch a few actions." Reach for SwiftUI first; the
declarative shape simplifies the work and the AppKit integration surface
(`NSHostingController`/`NSHostingView`) is small.

**AppKit owns surfaces where correctness depends on native rendering or the
responder chain**: the terminal pane (responder chain, IME, input latency), the
simulator pane (Metal rendering, custom hit-testing for letterboxed content,
multi-touch synthesis), the `NSStatusItem` menu bar, the main menu, custom
window/tab chrome, and sheets that need precise pre-existing macOS behavior
(modal alerts that respect window-modality semantics, file pickers).

**The dividing line is responder-chain or rendering specificity.** If a
surface needs precise control over draw timing, input dispatch order, or
responder chain participation, it's AppKit. Otherwise SwiftUI.

A PR that *moves* a surface across the line (SwiftUI → AppKit or vice versa)
needs an explicit justification line in the description.

## Architecture-checks review gates

Code-review checklist (not a static analyzer). Reviewers explicitly look for:

- **SwiftUI/AppKit boundary changes:** any PR introducing SwiftUI to a
  previously AppKit area (or vice versa) needs explicit justification per
  the rule above.
- **Private API boundary changes:** any new selector/protocol use in
  `CoreSimulatorBridge` adds a row to `as-tested.md`'s required-symbols
  table; the compatibility probe is updated to check it.
- **New RPC methods:** any new daemon RPC method requires (1) a new
  `RPCMethod` case in `DaemonProtocol` (never a raw string literal in the
  registry or a client) and (2) a matching update to the canonical schema
  doc in `docs/ARCHITECTURE.md`. The `DaemonTests` registry-drift guard fails if a
  registry key has no `RPCMethod` case; PRs that skip the schema update fail
  review.
- **Config key changes:** any new `~/.config/deviceterm/config` key needs a
  default value in `Config.swift`, a docs entry in `docs/BUILDING.md` (or wherever
  the user-facing config reference lives), and a fixture test.

These are review-time prompts, not automation.

## Trust boundary

The daemon vends two transports with different trust models. UDS (the CLI /
shim path) authenticates a session with a capability PLUS the caller's kernel
peer provenance (`LOCAL_PEERTOKEN` → the caller's POSIX session / controlling
tty, matched against the session's bound terminal). It is not cap-only. It
reaches `.orchestratorTab` scope (`tab.send-input`/`tab.capture`) only when its
session currently holds a **live orchestration grant**, re-checked per request;
authority is the grant plus that provenance, never a role. What UDS can never do
is *escalate*: it cannot mint an orchestrator role and cannot issue itself a
grant: both `orchestrator.grant`/`.revoke` and the orchestrator-role mint at
`session.create` are refused for anything but a validated-GUI XPC peer, so a UDS
caller can only exercise a grant the GUI already handed its session. XPC (the GUI path) validates the peer's audit token against the
daemon's own signature: the team identifier plus a host bundle id derived from
the daemon's own bundle id, so forks rebrand by swapping the bundle id with
nothing hardcoded. Full explanation and code: `docs/ARCHITECTURE.md` and
`Sources/Daemon/PeerIdentity.swift`.

**A capability is one authentication factor, not proof of provenance.** A
session's cap is inherited by that terminal pane's shell and is readable by any
same-uid process (`ps -E`), so possession alone establishes nothing about where
the caller is running. Sibling terminal panes hold distinct sessions, caps, and
terminal anchors, so the boundary is per terminal pane, not per tab. A session
authenticates only when a valid cap on a live session is joined by a matching
kernel-identity provenance arm: the validated GUI peer (XPC), the exact process
that created the session (owner, captured server-side at `session.create`,
never a wire-supplied pid), or the session's bound terminal (UDS: the caller's
POSIX session id, controlling tty, and session-leader start time must match the
anchor the GUI bound via `session.bindTerminal`). That terminal match, not the
cap, is what separates a caller sitting in the session's own terminal from a
cap thief elsewhere on the machine. The test is terminal membership, not
process ancestry: a descendant that detaches from the controlling terminal
stops matching the anchor.
Provenance is re-checked on every scoped request, so closing a session or
revoking its terminal anchor invalidates an already-authenticated socket; a
handler that takes a payload `(sessionId, cap)` also confirms the target equals
the connection's own provenance-checked session (only the validated GUI spans
sessions). Closing a session (hard revocation: session removal) additionally
tears down that session's live subscriptions before the close returns, not just
its next request: pane JSON/surface streams and its `daemon.events` stream stop
(a `.guiPeer` subscription is spared). Losing the terminal anchor on a
still-live session is the **soft, retryable pause** instead: it blocks new
calls while an already-open stream keeps flowing, and is not a hard revocation.
See `Sources/Daemon/ProvenanceMatcher.swift`.

## `DEVICETERM_SESSION_CAP`

`session.create` returns a capability token, injected as `DEVICETERM_SESSION_CAP`
into the terminal pane's shell env alongside `DEVICETERM_SESSION`,
`DEVICETERM_DAEMON_SOCK`, `DEVICETERM_SHIM_DIR`, and the `ZDOTDIR`/`PATH`
overrides. It is **one factor**, not proof of origin on its own: because it is
inherited env, any same-uid process can read it (`ps -E`), so possession alone
says nothing about where the caller runs. The daemon pairs it with the caller's
kernel terminal provenance (see the Trust boundary section) to draw the
cross-session boundary. Anything running in *this* shell's terminal (user CLIs,
scripts, agent processes) shares its controlling terminal and is trusted to
control the session, so the cap is deliberately visible to every child process.
Don't treat it as a secret, and don't strip it before launching subprocesses.

The CLI never asks the user about the cap. It reads the env cred once for the
session-scoped call that needs it and reuses the result. Never add a
credential-bearing parameter to a CLI verb, and never widen a wire shape with
`sessionId` + `cap` to force per-call threading; if per-call enforcement is ever
needed it lands at the connection layer, leaving individual method shapes
unchanged.

## Core Architecture Rules

`docs/ARCHITECTURE.md` carries the full system explanation. These are the
core rules to keep in hand at PR time:

- **Process ownership.** The daemon owns sims, IOSurface streams, HID/AX
  clients, the in-memory session and pane registries, the capability verifiers,
  and the status item. The GUI owns windows, tabs, pane rendering, the terminal
  PTY (libghostty `posix_spawn`s the shell in-process), and input translation.
  The CLI owns argv, JSON emission, and exit codes.
- **Every cross-process call is RPC.** The GUI never `dlopen`s CoreSimulator.
  Want something on the wrong side of the boundary? Design the RPC method first.
- **Narrow role protocols.** `DaemonClient` is the only concrete RPC client;
  consumers inject the narrowest role they use (`SessionControlling`,
  `DeviceControlling`, `PaneControlling`, `PaneSubscribing`) and are tested
  against `FakeDaemonClient`. Never store the concrete client outside
  `AppDelegate`; the `DaemonClienting` alias is for forwarding glue only.
- **IPC framing** over UDS is length-prefixed JSON:
  `[uint32 BE length][JSON bytes]`; over XPC the same envelope rides in an
  xpc dictionary. A future binary payload would ride as a base64 JSON
  string, but none exist today (renders pass XPC-marshalled IOSurfaces on
  a side-band, not inline bytes).
- **Status item visibility** is hidden at zero owned booted sims and `📱 N` when
  N > 0. Don't add a config key to override it: that visibility is how a
  daemon still holding orphaned sims stays discoverable.
- **CoreSimulatorBridge boundary.** No private selector or protocol is visible
  outside `Sources/CoreSimulatorBridge/`; it vends Swift wrappers
  (`SimDeviceHandle`, `SimDisplayHandle`, `SimHIDClient`, `SimAccessibility`,
  `SimPurpleHID`). A new selector lands with an `as-tested.md` row and a probe
  symbol.
- **Provenance.** A valid `(sessionId, cap)` is **necessary but not
  sufficient**: the cap is inherited env, readable by any same-uid process, so
  possession alone doesn't prove tab membership. The daemon authenticates a
  session only when the cap is joined by the caller's matching kernel identity
  (validated GUI, exact owner, or bound terminal, see the Trust boundary
  section), re-checked on every scoped request. Pane-targeted calls are
  additionally authorized per-request against the caller's pane ownership
  (`PaneCoordinator.authorize`): a session reaches only its own panes, the
  validated GUI peer spans sessions, and a foreign paneId is a hard reject
  indistinguishable from an unknown one. No cap logged either way.
