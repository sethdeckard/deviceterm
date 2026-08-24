# Building DeviceTerm

## Prerequisites

- **Apple Silicon Mac running macOS 14 or later** for building and running
  DeviceTerm.
- **Xcode 26.4 or 26.6.** These are the toolchains currently verified to build
  DeviceTerm. Other Xcode releases are unverified; Xcode 27 beta does not
  currently build the project.
- **Swift 6.2 or later**, included with supported Xcode releases. The
  manifest declares `swift-tools-version: 6.2`, so an older toolchain
  refuses to load the package.
- **SwiftLint**: `brew install swiftlint`. Required for `make lint`/`make verify`.
- **Apple Developer ID Application certificate**: required for a
  fully-launchable bundle. The daemon registers via
  `SMAppService.agent(...)`, and launchd's Launch Constraints reject
  ad-hoc-signed agents on macOS 26, so `make bundle` doesn't fall back
  to ad-hoc. Without Developer ID it leaves the bundle unsigned: the
  GUI starts, the daemon can't demand-launch. Configure via
  `.env.release`'s `CODESIGN_IDENTITY`. A free Apple Account tier
  is insufficient: the Developer ID cert family ships only with
  paid Developer Program membership ($99/year). Without credentials,
  `make bundle` and `make verify` still complete (unsigned bundles
  assemble and pass smoke checks) but the bundle isn't launchable
  end-to-end. The separate `--ephemeral` mode creates a per-run
  temporary bundle and ad-hoc signs it.

### Select the active Xcode

DeviceTerm, `xcrun`, SwiftPM, and the compatibility probe use the active
developer directory. To make an installed Xcode the command-line default:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcode-select --print-path
xcodebuild -version
```

Use the actual app name when it differs, for example:

```sh
sudo xcode-select --switch /Applications/Xcode-26.4.app/Contents/Developer
sudo xcode-select --switch /Applications/Xcode-26.6.app/Contents/Developer
```

For a one-command test without changing the system default, set
`DEVELOPER_DIR` for that invocation:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.app/Contents/Developer make build
```

This compiler/toolchain support is separate from the Simulator services and
physical-device stream protocols DeviceTerm talks to at runtime. Those
compatibility boundaries are documented in [`USAGE.md`](USAGE.md#runtime-compatibility).

## First-time setup

```sh
git clone <…>
cd deviceterm
make hooks            # one-time: activate + check .githooks/
make verify           # confirm the tree is green
```

`make hooks` points `core.hooksPath` at `.githooks/` and rejects any hook
there that isn't executable or doesn't parse. Git skips a non-executable
hook with only a hint that's easy to miss mid-checkout, so this fails at
install time instead.

That activates `post-checkout` alongside `commit-msg`. It links
`.env.release` from this checkout into worktrees you create later, so both
sign with the same identity (when this checkout has no `.env.release` yet,
the hook prints the command to wire it up afterward). The file may hold
inline notarization credentials, so every worktree linked this way can read
them; the recommended `NOTARY_PROFILE` setup keeps the app-specific
password in the Keychain instead.

## Day-to-day

```sh
make build            # build in debug
make run              # build + open DeviceTerm.app
make test             # unit tests (Swift Testing)
make test-gui         # GUI smoke (scripts/gui-smoke.sh; --smoke-driven)
make lint             # swiftlint --strict
make verify           # the single-command gate
```

`verify` self-skips checks whose backing source/script doesn't exist yet
and runs the rest. Green tree always exits 0. See the verify shape note in
`../AGENTS.md`.

**Warnings are errors.** Every first-party target sets
`.treatAllWarnings(as: .error)`, so an unused variable or a deprecated
call fails the build instead of scrolling past in the log. This applies
to debug and release alike, and to `swift build`, `swift test`, and an
IDE, because it lives in `Package.swift` rather than a build flag. The
dependencies keep their own settings. If an SDK deprecation ever blocks a
release you can't wait out, `.treatWarning("DeprecatedDeclaration", as:
.warning)` next to the rule is the exemption.

**GUI smoke.** `make test-gui` runs `scripts/gui-smoke.sh`, which launches
the bundled `DeviceTerm.app --smoke`. The `--smoke` handler drives Router
dispatches headlessly (first window+tab, daemon round-trip, newTab,
closeTab, second window open, selectWindow, closeWindow) and asserts nav
state, exiting 0 on success. The same script runs inside `make verify`, so
the default gate catches dispatch/reconcile regressions. There is no
XCTest UI target: by project tenet (no `.xcodeproj`) this script is the
only GUI gate; modal prompts, real-sim flows, the status item, and ⌘Q live
in `Tests/Manual`.

## Working in multiple worktrees

Add one the ordinary way:

```sh
git worktree add ../deviceterm.my-topic -b topic/my-topic
```

With `make hooks` run once in the main checkout, `post-checkout` fires on
the new tree. If the main checkout contains `.env.release`, the hook
symlinks it in and prints the link, so both worktrees read the same
release configuration; if it doesn't, the hook says so. Signing itself
follows `CODESIGN_IDENTITY`, which that file or your environment can
supply. Without it, development bundles are left unsigned and the
embedded daemon cannot launch.

The hook is versioned in the repo, so a worktree added from a branch that
predates it gets nothing, and the script isn't there to run either. Update
that worktree to a revision containing the hook, then from inside it:

```sh
.githooks/post-checkout '' HEAD 1
```

Building, testing, and linting are per-checkout. `.build/` belongs to the
tree it sits in, the daemon tests bind sockets keyed by pid and a UUID
fragment, the GUI smoke redirects `HOME` and the daemon socket to a temp
dir, and `verify`'s stale-SwiftPM check counts only tooling belonging to
this checkout. Run `make build`, `make test`, `make lint`, and
`make verify` in as many trees as you like.

**The app and the daemon are machine singletons.** One bundle id, one
launchd label, one mach service, so a second checkout's app would talk to
whichever daemon is already registered. `make run` relaunches its own
checkout's app and refuses when it sees another checkout's, or
`/Applications/DeviceTerm.app`, already running, naming the owner in the
refusal. Quit it from there; there is no force flag. `make kill-daemon`
signals only pids running from this checkout's `.build`, and says nothing
about a foreign instance.

That refusal depends on `pgrep`, which a sandboxed shell can be denied. A
guard that cannot enumerate proceeds rather than claiming BUSY without
evidence, so `make run` from a blind shell can launch alongside another
checkout's app.

**The three deliberate test tracks take a lock**, because each drives
state the whole login session shares:

| Track | Lock | What it would otherwise clobber |
|---|---|---|
| `make test-live` | `sim` | the simulator fleet, which the track shuts down for a clean slate |
| `make test-device-live` | `device` | the connected device and its CoreDevice tunnel |
| `make test-uitest` | `uitest` | the shared harness bundle in `~/Applications` and the GUI it drives |

A lock is a directory at `/tmp/deviceterm.<uid>.<track>.lock`, so it is
per-user, not machine-wide. A second run refuses immediately with a
`deviceterm-make: BUSY:` block naming the holder, and there is no wait
mode. The lock helper exits 75 (`EX_TEMPFAIL`); run through a make target
that reads as `Error 75` with make itself exiting 2, so the
`deviceterm-make: BUSY:` prefix is the stable signal rather than the exit
code. `make uitest-run`, `make uitest-bundle`, and `make uitest-stop` take
the `uitest` lock too, since they rewrite or stop the shared harness.

The harness track has one overlap a lock doesn't cover. `make verify` and
`make test-gui` launch a real `com.deviceterm` GUI for about two seconds,
from whichever checkout runs them, and it spawns its own daemon. Rather
than serialize the gate that every commit runs, the harness checks its
target per request: if that request's snapshot is ambiguous, it fails with
the matching pids instead of dumping or screenshotting the wrong instance.
Rerun the track once the smoke is done.

Inspect a lock:

```sh
./scripts/exclusive-lock.sh status sim
```

A lock whose owner has exited is reclaimed by the next run, so an
inherited one normally needs nothing from you. Reclaiming demands positive
evidence that the recorded owner is gone, either `kill -0` reporting ESRCH
or the pid's start time no longer matching what was recorded, plus nothing
left alive in the owner's process group. Anything ambiguous, an EPERM
under a sandbox for instance, counts as live, so a blind shell never
steals a lock from a running track. The one state that cannot clear
itself is a dead owner whose process group could not be recorded at
acquire time, and its BUSY block carries a `fix:` line naming the
directory to remove. Confirm no track is running in any checkout before
you remove it.

`make release` writes into its own checkout's `release/`. `make publish`
pushes to the shared tap checkout (`$DEVICETERM_TAP_DIR`, default
`../homebrew-tap`) and creates the GitHub release. Nothing guards those,
so coordinate them yourself.

## Configuration

DeviceTerm preferences live in `~/.config/deviceterm/config` (or
`$XDG_CONFIG_HOME/deviceterm/config` when that variable is set),
Ghostty-style `key = value` with `#` comments. Preferences live in
this one file, never in `UserDefaults` or other scattered app state.
The file is hand-editable; DeviceTerm rewrites only the specific key when a
preference changes, preserving every comment, blank line, and unknown key
verbatim.

Terminal appearance and terminal-local key bindings are a separate domain.
libghostty loads the user's normal Ghostty configuration, including
`~/.config/ghostty/config`. Neither configuration overrides the other because
their recognized keys are disjoint. The app ignores unknown DeviceTerm keys;
`deviceterm dump-config` reports them as warnings.

| Key | Values | Default | Behavior |
|---|---|---|---|
| `tab-close-default` | `detach`, `shutdown` | `detach` | Suppresses the Close Tab, Close Window, and Close Pane prompts and picks this action. `detach` closes the surface but keeps any sims it booted running; `shutdown` also stops them. Close Pane still asks when DeviceTerm cannot reach the daemon to check the Simulator. |
| `tab-close-multi-pane` | `ask`, `close` | `ask` | Confirms before a GUI close of a tab that holds more than one pane, and of a window when any of its tabs does; shell-exit and `deviceterm` CLI closes never prompt. `close` skips the confirmation. When the same close would also raise the sim prompt above, only the sim prompt shows. |
| `quit-with-sims-default` | `keep`, `shutdown` | `keep` | Suppresses the Quit prompt when DeviceTerm-owned sims are booted. `keep` quits leaving them running; `shutdown` stops every owned booted sim first. Has no effect when no owned sims are booted. |
| `simulator-app-advisory` | `show`, `suppress` | `show` | Whether to show the Simulator.app coexistence advisory when a sim is attached while Apple's Simulator.app is also running. The advisory names only the shutdown routes still open and stays silent when Simulator.app is configured to detach on both. `suppress` hides it. |
| `welcome-messages` | `show`, `suppress` | `show` | Whether to show first-run welcome windows, which explain a DeviceTerm behavior once. `suppress` hides every welcome, including ones not yet seen; each stays reachable from the Help menu. |
| `auto-update` | `off`, `check`, `download` | `check` | How the app handles updates via Sparkle. `check` checks automatically and notifies when an update is available; `download` also installs it on relaunch; `off` disables automatic checks (the Check for Updates… menu item still works). |

Most of these keys are written when the user ticks "Don't ask again" /
"Don't show again" on the matching prompt; deleting one from the file
restores the prompt. `welcome-messages` is the exception: a welcome
appears automatically only until its id is recorded, so a checkbox would
have nothing to suppress, and you set the key by hand. When DeviceTerm
writes the file it makes it
self-documenting: each key the app sets is preceded by a doc comment
(summary, allowed values, default), and every recognized key the user
hasn't set is appended as a commented-out example, so the file lists
every available option. Hand-edited lines, comments, and unknown keys
are preserved verbatim.

Which welcomes have already appeared is not a preference and is not kept
here. It lives in `$XDG_CACHE_HOME/deviceterm/welcome-seen` (or
`~/.cache/deviceterm/welcome-seen`), one id per line. Delete a line to
show that welcome again on the next launch. Losing that file re-shows
each welcome once, which is the cost of keeping app-written bookkeeping
out of a file you hand-edit.

### Saved locations

A second, separate file, `~/.config/deviceterm/locations` (or
`$XDG_CONFIG_HOME/deviceterm/locations`), holds the places listed under
Device ▸ Location. It is not `key = value`: each entry is either
`<latitude>,<longitude> [name]` or `<path>.gpx [name]`, the name running
to the end of the line. A path containing spaces is double-quoted. Blank
lines and full-line `#` comments are allowed; a `#` later in a line is
part of the name. Coordinates parse as POSIX
regardless of the user's locale, so the file means the same thing to
everyone who opens it; the Custom Coordinates sheet is the opposite,
accepting a decimal comma from whoever is typing.

Semantics are **append-only**: DeviceTerm adds an entry when the user
sets a custom coordinate (deduplicated by position, so re-picking one
adds nothing and never overwrites the name the user gave it), and does
nothing else. It never reorders, caps, or evicts, because file order is
menu order and a capped MRU would eventually delete a line somebody
typed by hand. As with `config`, comments, blanks, and lines this
version doesn't recognize survive a write byte-for-byte, so a line the
current parser can't read is preserved rather than dropped.

## Shell completions + man page

Shell completions install via the CLI itself: `deviceterm completions
install <zsh|bash|fish>` writes the per-shell script to the
conventional autoload path (honoring `XDG_DATA_HOME` /
`XDG_CONFIG_HOME` when set) and prints the install path + a one-line
hint covering the rc-file change that enables it (zsh `fpath`, bash
`source`, fish autoload).

The man page is hand-authored at `share/man/man1/deviceterm.1`. From a
checkout, browse the canonical copy with
`man -l share/man/man1/deviceterm.1`.

## libghostty

The terminal pane is libghostty-backed (Ghostty's renderer + input +
parser, no app shell). libghostty isn't built here; it's a
prebuilt SwiftPM binary package, [`libghostty-spm`][lg], pinned in
`Package.swift`:

```swift
.package(
    url: "https://github.com/sethdeckard/libghostty-spm.git",
    exact: "0.1.0"
)
```

SwiftPM fetches a checksummed `GhosttyKit.xcframework` from the
package's GitHub release, and the `GhosttyKitResources` module ships
libghostty's runtime resource tree (the `terminfo` sentinel +
`ghostty/shell-integration` + `ghostty/themes`) in-package via
`Bundle.module`. Nothing is vendored in DeviceTerm (no zig
toolchain, no Ghostty source, no `Vendor/` tree), so a fresh clone just builds.

`LibghosttyBridge` is the only target that imports `GhosttyKit` / sees
`ghostty.h`. `LibghosttyHarness` additionally depends on
`GhosttyKitResources` and points libghostty at
`GhosttyKitResources.directoryURL` (overridable for local Ghostty
checkouts via `DEVICETERM_LIBGHOSTTY_RESOURCES`).

DeviceTerm reads your Ghostty config in two places: libghostty loads it
wholesale when the first terminal pane bootstraps the runtime, and the
app chrome side-reads `background` / `selection-background` to tint
itself.

Set `DEVICETERM_IGNORE_GHOSTTY_CONFIG=1` to skip both for a launch and
see the app in its default theme, without touching your dotfiles. Only
the exact value `1` enables it. `make run-default` sets the variable and
delegates to `make run`.

### Bumping libghostty

The libghostty C API is not versioned by upstream, so treat every bump
as an API audit. The Ghostty pin, the fragile zig/Metal build, and the
embedding-symbol release gate all live in `libghostty-spm`. There is
nothing to build here. Bumping is: raise the `exact:` version in
`Package.swift` to a newer `libghostty-spm` tag, then `make verify` to
confirm `LibghosttyBridge` still compiles against any `ghostty.h`
changes.

[lg]: https://github.com/sethdeckard/libghostty-spm

## Code signing & release

DeviceTerm is distributed through a Homebrew Cask and a direct DMG download.
Both use the same Developer ID-signed and notarized app. Private CoreSimulator
APIs preclude the App Store sandbox.

### Required environment

- `CODESIGN_IDENTITY`: Developer ID Application certificate identity, for
  example `"Developer ID Application: Your Name (TEAM123ABC)"`.
- Notarization credentials, either `NOTARY_PROFILE` for a stored `notarytool`
  keychain profile or `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`.

Copy `.env.release.example` to `.env.release`; the release scripts load it
automatically. Publishing also needs the Sparkle private key in the login
Keychain.

### Building a release

```sh
make release
```

`make release` runs `scripts/build-release.sh --dmg`:

1. `swift build --configuration release`.
2. Bundle into `DeviceTerm.app` (`make-app-bundle.sh`), embedding
   `deviceterm-daemon.app` at `Contents/Library/LoginItems/` and
   `Sparkle.framework` at `Contents/Frameworks/`.
3. Confirm the embedded daemon exists at the expected path.
4. `codesign` inner to outer (hardened runtime + secure timestamp): helpers,
   **the Sparkle framework's nested XPC services / Autoupdate / Updater.app,
   then the framework bundle**, the daemon, then the outer app.
5. `codesign --verify --deep --strict DeviceTerm.app`.
6. Zip + submit to `notarytool --wait`, staple; build the DMG, sign +
   notarize + staple it too.
7. Gatekeeper assessment (`spctl`).

Publishing (`make publish`, after a release build) is a separate local
step: it refreshes the Homebrew cask, generates the appcast, and creates
the GitHub release. See [`RELEASING.md`](RELEASING.md).

### Sparkle update signing

Sparkle verifies updates with an **EdDSA (ed25519) key pair** that is
independent of your Apple Developer ID:

- Generate the key once with Sparkle's `generate_keys` (ships in the Sparkle
  distribution). The **private** key is stored in your login Keychain; the
  printed **public** key goes into `SUPublicEDKey` in
  `Sources/App/Resources/Info.plist` (a placeholder ships in the repo).
- At publish time, `generate_appcast` signs each release with the private
  key and writes `appcast.xml`; `make publish` uploads it as a release asset
  so the `SUFeedURL` permalink serves the newest feed.
- **Back up the private key**: it can't be re-issued, and losing it means
  existing installs can't verify future updates. See `RELEASING.md`.

### Location permission

Device ▸ Location ▸ Use My Location reads this Mac's position through
CoreLocation, which macOS gates behind a TCC prompt. The prompt appears
only when `NSLocationWhenInUseUsageDescription` is present in the running
bundle's `Info.plist`. It ships in `Sources/App/Resources/Info.plist`, and
`scripts/make-app-bundle.sh` copies that file into `DeviceTerm.app`.

**No entitlement is involved.** As with the tunnel sockets below,
`com.apple.security.personal-information.location` is an *App Sandbox*
key and would be a no-op in a non-sandboxed, hardened-runtime build. The
usage string is the whole requirement, and only the GUI links
CoreLocation: the daemon never touches TCC.

The consequence for development is that Use My Location needs `make run`,
not `swift run`. A bare binary has no bundle, so it has no usage string,
so macOS never prompts and CoreLocation never answers. DeviceTerm detects
that case and says so in an alert rather than waiting on a prompt that
will not arrive. Everything else in the submenu works either way.

### Physical-device panes: daemon scope & entitlements

Mirroring a physically-connected iPhone/iPad runs entirely inside the
**`deviceterm-daemon`** helper: it directly links the physical-device targets
(`DeviceReachability`, `ChannelBootstrap`, `InteractionRelay`, and
`MirrorPipeline`). `MirrorPipeline` supplies the VideoToolbox, CoreMedia,
CoreVideo, and IOSurface framework links. The daemon talks to the device over
the OS CoreDevice tunnel (a `utun` ULA-IPv6 interface) with plain BSD sockets
and decodes the device's video stream to IOSurface in-process.

Two deliberate properties keep this shippable without new signing surface:

- **User-scope, no root: DeviceTerm holds the tunnel itself.** The daemon is a
  lazy-spawned, idle-exiting `LSUIElement` helper bundle: no privileged helper,
  no `SMJobBless`, no setuid. The OS tunnel is
  created and held by Apple's root daemons (`remoted`/`remotepairingd`),
  which a Developer-ID app cannot drive directly (those entry points are
  gated by private `com.apple.private.RemoteServiceDiscovery.*`
  entitlements). So instead of *reusing* a tunnel some other app
  (Xcode/Device Hub) happens to hold up, the daemon **borrows Apple's own
  signed `devicectl`**: a benign blocking `devicectl device notification
  observe --device <udid>` subprocess (`TunnelKeepalive`) parks a trusted
  CoreDevice session, which keeps the `utun` up; it's SIGINT'd when the last
  pane mirroring that device closes. Enumeration is `devicectl list devices`
  (usbmux/lockdown, works with the tunnel down). Both are `xcrun devicectl`
  invocations: Apple's binary makes the privileged ask; the daemon stays
  user-scope.
- **No daemon-specific entitlement needed.** The app and its helper run
  **without the App Sandbox** (private CoreSimulator APIs preclude it), so
  the hardened runtime is the only constraint at notarization. Hardened
  runtime doesn't gate BSD-socket networking or spawning `xcrun`:
  `getifaddrs` / `getaddrinfo` / `connect()` over the tunnel and
  `Process`-spawning `devicectl` work without any entitlement. The
  `com.apple.security.network.*` keys are *App Sandbox* entitlements and
  would be no-ops here; we deliberately don't add a separate daemon
  entitlements plist. The existing release flow already signs the daemon
  binary + bundle with `--options runtime` + timestamp.

On a clean daemon exit `TunnelKeepalive.shutdownAll()` SIGINTs every
borrowed `devicectl`; a crashed daemon's orphans self-exit at their
`--session-timeout` and are reaped (`TunnelKeepalive.reapOrphans()`, keyed
on a unique observe notification name) the next time the daemon launches.

Captured personal-device frames stay in-process (IOSurface streamed to the
GUI for rendering) and are **never persisted**. The daemon persists no
session/ownership/pane state at all: a restart drops every pane and
ownership record, and mirrors recreate through the normal attach path, which
the GUI runs itself for any pane still on screen when the daemon comes back.

## UI-test harness (dev/test only)

`deviceterm-uitest` is an out-of-process instrument that screenshots and
drives DeviceTerm's GUI, so an agent running inside a DeviceTerm tab can
verify what the CLI's `--json` state claims. It is never part of a
release: `scripts/build-release.sh` doesn't bundle it, and nothing in
`DeviceTerm.app` depends on it.

It exists as a separate app for one reason. macOS attributes Screen
Recording and Accessibility to the process that calls the API, resolved
through that process's *responsible* process. A bare binary run from your
shell attributes to your terminal, so granting it would hand your
terminal broad capture and input rights, and capturing from inside
DeviceTerm would hand them to DeviceTerm. Launching a signed, faceless
`.app` through LaunchServices gives it its own identity, so the grants
land on the harness and nowhere else.

```sh
make uitest-run     # build + bundle + launch the resident, then report grants
make uitest-stop    # stop it
```

### One-time grants

`make uitest-run` bundles the harness to
**`~/Applications/DeviceTermUITestHarness.app`**, a visible, stable
location (not the hidden `.build` tree, which the Privacy "+" picker can't
reach and `make clean` wipes), launches it, and prints a `doctor` report.
If either grant is missing it then **reveals the app in Finder and opens
the two Privacy panes for you**, so the one-time setup is drag-and-toggle
rather than a hunt:

1. In each pane that `make uitest-run` opened, **Screen Recording** and
   **Accessibility**, drag `DeviceTermUITestHarness.app` from the revealed
   Finder window onto the list (or click `+`).
2. Toggle it on in both.
3. Re-run `make uitest-run`; `doctor` now exits 0 with both grants.

The two permissions:

- **Screen Recording**: ScreenCaptureKit reads the composited window
  server, so Metal-rendered simulator/device panes appear exactly as a
  human sees them. An in-app self-render would miss those layers.
- **Accessibility**: reading DeviceTerm's AppKit accessibility tree and
  posting the GUI-only gestures (menu clicks, drag, keyboard shortcuts)
  that have no CLI equivalent. It is also the only way to dismiss an
  app-modal `NSAlert`, which blocks DeviceTerm's own main run loop. The
  tab, pane, and window close prompts are window-modal sheets and don't
  block, but plenty of alerts still do, the quit-with-sims prompt and
  cold-start orphan recovery among them.

With `CODESIGN_IDENTITY` set in `.env.release` the harness is signed with a
stable Developer-ID identity, so TCC keys on the signature (not a
per-build cdhash) and (combined with the fixed `~/Applications` path) the
grant is genuinely one-time, surviving rebuilds and `make clean`. Without
it the bundle is ad-hoc signed and its code signature changes on every
rebuild, so macOS may silently drop the grant; if capture starts failing
after a rebuild, toggle the harness off and on in System Settings.

### Talking to it

The resident serves a private UDS socket
(`~/Library/Caches/deviceterm/uitest.sock`, overridable with
`DEVICETERM_UITEST_SOCK`). Every other verb is a short-lived client that
forwards one request, so the capture APIs always execute inside the
resident: the client never touches them, and nothing rolls attribution
back to your shell.

```sh
deviceterm-uitest ping
deviceterm-uitest doctor
deviceterm-uitest capture window --out /tmp/win.png       # DeviceTerm's frontmost window (incl. a modal alert)
deviceterm-uitest capture status-item --out /tmp/badge.png # just the daemon's menu bar badge window
```

The harness **only ever captures DeviceTerm's own windows, never a whole
display**: it can't screenshot other apps or the desktop. The status
item belongs to the *daemon*, not the app, and is a menu-bar-layer window of
its own, so it is captured via `capture status-item` (not a window capture of
the app, and not a display capture). When no owned sim is booted the badge is
hidden and `capture status-item` reports `present:false` with no PNG.

### Smoke track and the E2E skill

`make test-uitest` is a deliberate, non-hermetic track (like `make
test-live`): it builds the harness + `DeviceTerm.app`, ensures the resident
and both grants are present, launches DeviceTerm, and runs a **sim-free**
smoke subset end to end: a real capture, a well-formed AX dump, and the
direct evidence that a harness-driven "New Tab" gesture changes the tab
count the CLI reports. It needs the TCC grants and an unlocked display, so
it stays out of `make verify` / `make test` and self-skips when the harness
source is absent. It never boots or shuts down a simulator.

The richer, sim-touching scenarios (pending-pane lifecycle, status-item
count, close/quit prompts, the device picker) are driven interactively by an
agent through the `deviceterm-e2e` skill: one neutral playbook at
`.agents/skills/deviceterm-e2e/PLAYBOOK.md`, with Claude and Codex
frontmatter shims under `.claude/` and `.codex/`. Those require a
user-nominated throwaway sim and are not automated here.
