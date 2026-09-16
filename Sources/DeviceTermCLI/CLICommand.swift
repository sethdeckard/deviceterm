// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// What an argv dispatches to. Pure: no I/O, no env. Tests assert on
/// this enum to pin dispatch behavior without spawning a process. The
/// `pane` on each pane-targeted case is the optional targeting ref
/// (from `--pane`); `resolvePane` in `CommandDispatch.swift` resolves
/// it to a concrete paneId via `pane.deviceList` + `PaneRefResolver`.
///
/// Kept free of side effects so Tests/CLITests can drive the parse
/// directly. `CLIMain` and the command runners own env reads, stderr,
/// socket I/O and `exit`; this enum is the deterministic result of
/// reading argv.
///
/// Grammar (locked): required operands are positional, optional modifiers
/// are flags, and `--pane <ref>` is the shared targeting selector that
/// picks among the tab's device panes. A `<ref>` resolves a shortId,
/// name, pane UUID prefix, sim UDID, or physical deviceId (omit it when
/// the tab shows a single device pane). `--duration`, `--hold`,
/// `--velocity`, and `--step` are the input-specific modifiers.
public enum CLICommand: Equatable, Sendable {
    case tap(
        pane:
        String?,
        x: Double,
        y: Double
        )
    /// `deviceterm tap (--identifier <value>|--label <value>) …`: block until
    /// the selector names one eligible coordinate target, then tap its centre.
    ///
    /// Shares its selection with `wait ax --print center`, so the element that
    /// mode names is the element this taps. Separate from `.tap` because the
    /// two take different operands: one is handed a coordinate, the other
    /// resolves one.
    case tapElement(
        pane: String?,
        query: WaitAXQuery,
        timeoutMs: Int
        )
    case swipe(
        pane:
        String?,
        fromX: Double,
        fromY: Double,
            toX: Double,
        toY: Double,
        durationMs: Int?,
        holdMs: Int?
        )
    /// `deviceterm app-switcher`: open the iOS App Switcher. Sugar over a
    /// `swipe` with an active dwell: swipe up from the bottom edge to
    /// mid-screen, hold, then lift. Portrait coords; for a rotated
    /// device use `swipe … --hold` with rotated coordinates.
    case appSwitcher(
        pane:
        String?
        )
    case longPress(
        pane:
        String?,
        x: Double,
        y: Double,
        durationMs: Int?
        )
    case pinch(
        pane:
        String?,
            fromF1X: Double,
        fromF1Y: Double,
        fromF2X: Double,
        fromF2Y: Double,
            toF1X: Double,
        toF1Y: Double,
        toF2X: Double,
        toF2Y: Double,
            durationMs: Int?
        )
    case button(
        pane:
        String?,
        button: HardwareButton
        )
    case key(
        pane:
        String?,
        keyCode: UInt32,
        down: Bool
        )
    case text(
        pane:
        String?,
        text: String
        )
    case rotate(
        pane:
        String?,
        target: RotationTarget
        )
    case crown(
        pane:
        String?,
        delta: Double,
        velocity: Double?,
        durationMs: Int?
        )
    case axTree(
        pane:
        String?
        )
    case axPoint(
        pane:
        String?,
        x: Double,
        y: Double
        )
    case axSweep(
        pane:
        String?,
        step: Double?,
        budgetMs: Int?
        )
    case waitPane(pane: String?, state: PaneLifecycle, timeoutMs: Int)
    /// `state` is the condition, not part of the query, which is why it does
    /// not live on `WaitAXQuery`: `tap` takes the same selector and has no
    /// use for a direction to wait in.
    case waitAX(
        pane: String?,
        query: WaitAXQuery,
        timeoutMs: Int,
        printMode: WaitAXPrint?,
        state: WaitAXState
    )
    case waitOrientation(pane: String?, orientation: Orientation, timeoutMs: Int)
    /// `deviceterm wait surface quiescent [--settle <ms>]`: block until the
    /// pane's rendered surface has stopped changing for `settleMs`.
    ///
    /// The condition after a change with no element to wait for: a Dynamic
    /// Type switch, a theme flip, an animation settling. The alternative is
    /// `sleep`, which is either too short or wasted time.
    case waitSurfaceQuiescent(pane: String?, settleMs: Int, timeoutMs: Int)
    /// Explicit help request: `deviceterm --help`, `deviceterm -h`, or
    /// `deviceterm help`. The command list and any known page write to
    /// stdout and exit 0; an unknown topic fails with suggestions.
    ///
    /// `topic` is nil for a bare trigger. Otherwise it is the longest
    /// leading run of non-flag tokens naming a declared command path
    /// (`tab show`, space-separated), falling back to the first
    /// non-flag token for a verb the command tree does not declare
    /// (`deviceterm help crown`). It is not validated here: the
    /// dispatcher resolves a declared path through `CommandTree` and
    /// anything else against `HelpCatalog`, which is what lets the
    /// unknown-topic error carry suggestions instead of collapsing into
    /// the terse usage block.
    case help(
        topic:
        String?
        )
    /// `deviceterm agents`: long-form workflow + triage guide. Caller
    /// writes `AgentsText.documentation` to stdout + exits 0. The
    /// deeper-read complement to `--help`.
    case agents
    /// `deviceterm doctor`: env + daemon + session diagnostic. Runs
    /// the checks in `Doctor`, prints a structured report, and
    /// exits 0 when every check is ok or warn, 1 when any check
    /// fails. Supports `--json` via the global output-mode toggle.
    case doctor
    /// `deviceterm with-pane <ref> <cmd…>`: resolves
    /// the device pane matching `<ref>` (shortId, name, sim UDID,
    /// physical deviceId, or paneId prefix), injects
    /// `DEVICETERM_TARGET_PANE=<key>` into the env, and execs `<cmd…>`.
    /// Downstream `deviceterm tap` / `swipe` / etc. inside `<cmd…>`
    /// auto-target the resolved pane. Sugar for the `--pane` flag at
    /// every subprocess call.
    case withPane(
        ref:
        String,
        cmd: [String]
        )
    /// `deviceterm events`: subscribes to the daemon's `daemon.events`
    /// stream and prints one JSON object per event to stdout until
    /// the daemon closes the connection or the process is killed.
    /// Events cover pane state changes, device boot/shutdown, and
    /// session create/close. Output is always JSON (no human
    /// format). Agents pipe through `jq`.
    case events
    /// `deviceterm version`: prints the public release, live daemon
    /// wire, bundled RPC wire, and macOS versions. Human columns by
    /// default; `--json` emits the `VersionReport` struct.
    case version
    /// `deviceterm dump-config`: prints every recognized
    /// `~/.config/deviceterm/config` key with its current value and
    /// source layer (default or file). Warns on unrecognized keys
    /// in the file.
    case dumpConfig
    /// `deviceterm completions install <zsh|bash|fish>`: generates
    /// the per-shell completion script and writes it to the
    /// conventional autoload path (`Completions.defaultInstallPath`).
    /// The caller prints the install path and a one-line activation
    /// hint pointing at the rc-file change that enables it.
    case completionsInstall(
        shell:
        Completions.Shell
        )
    // MARK: - Workspace verbs (tab / pane / window)
    //
    // These verbs publish via the daemon → GUI back-channel
    // (`app.commands`). Daemon stamps the originating session id;
    // the GUI's IntentDispatcher resolves the refs and either
    // dispatches a Route or reads workspace state for info verbs.
    // `current` is the implicit default when a `--tab` / `--pane` /
    // `--window` ref is omitted.

    case tabList(window: String?, all: Bool)
    case tabShow(tab: String?)
    /// `deviceterm tab open [--window <ref>] [--cwd <path>] [--command '<cmd>']`:
    /// mints a new agent-role tab in the chosen window (defaults
    /// to the caller's own window, not the human's key window). `--cwd`
    /// overrides the new shell's
    /// startup directory; `--command '<cmd>'` is typed into the shell
    /// after attach (libghostty's `initial_input`) so the command
    /// runs once and leaves the user at an interactive prompt.
    case tabOpen(
        window: String?,
        cwd: String? = nil,
        command: String? = nil
    )
    /// `deviceterm tab close [<ref>] [--mode <detach|shutdown>]`:
    /// closes the named tab (default: caller's current tab) with
    /// the chosen close mode for any linked sims.
    case tabClose(
        tab: String?,
        mode: WorkspaceCloseMode
        )
    case tabRename(tab: String?, name: String?)
    case tabFocus(tab: String?)
    case tabMove(tab: String?, window: String, index: Int?)
    case tabProtect(tab: String?)
    case tabUnprotect(tab: String?)
    case paneList(tab: String?, all: Bool)
    case paneShow(pane: String?)
    case paneSplit(pane: String?, direction: WorkspaceSplitDirection)
    case paneFocus(pane: String?)
    case paneClose(pane: String?, mode: WorkspaceCloseMode?)
    case paneRename(pane: String?, name: String?)
    case paneSendInput(pane: String, text: String, typeDelay: Int?)
    case paneCaptureText(pane: String, ansi: Bool)
    /// `deviceterm device attach <ref>`: the unified explicit-attach
    /// verb. `<ref>` resolves against the `devices.list` roster to any
    /// device: an already-booted/orphan **sim** (claimed into the
    /// caller's current tab via the existing attach pipeline) or a
    /// connected **physical device** (mirrored as a device pane).
    /// Idempotent when the device is already attached to the same tab.
    /// An explicit attach rejects a physical device already mirrored in
    /// another tab; move it with a GUI drag.
    case deviceAttach(
        ref:
        String
        )
    /// `deviceterm devices list`: the aggregate live roster (owned booted sims
    /// + connected physical devices), each annotated with its pane /
    /// ownership state. Backend roster complement to `pane list`; backed by the
    /// session-scoped `devices.list` RPC. Not a `simctl list` clone.
    /// Never enumerates shutdown / never-booted sims.
    case devicesList
    /// `deviceterm window open`: mint a new window with one fresh
    /// agent-role tab.
    case windowOpen
    case windowList(all: Bool)
    case windowShow(window: String?)
    /// `deviceterm window close [<ref>] [--mode <detach|shutdown>]`:
    /// close the named window (default: the caller's own window, not
    /// the human's key window; refused if it also holds a tab the caller
    /// can't see).
    case windowClose(
        window: String?,
        mode: WorkspaceCloseMode
        )
    /// `deviceterm window focus [<ref>]`: bring the named
    /// window forward.
    case windowFocus(
        window: String?
        )

    /// Text the parser answered with itself: a completion callback's
    /// candidates, or a generated completion script. It prints to
    /// stdout and exits 0.
    ///
    /// These arrive as thrown values because ArgumentParser signals
    /// them the way it signals a failure, so they have to be told apart
    /// by their exit code. Rendering one as a usage error puts the
    /// candidates on stderr behind a usage block, which is both useless
    /// to the shell asking and noise in the user's command line.
    case cleanExit(text: String)

    /// Anything else: caller prints usage to stderr and exits 1.
    case usage(
        message:
        String?
        )

    public enum WaitAXSource: String, Equatable, Sendable {
        case tree
        case sweep
    }

    /// How `wait ax` compares its primary selector against an element's
    /// `identifier` or `label`.
    ///
    /// `contains` folds case; `exact` does not. Live labels carry unread
    /// counts, truncation ellipses, and interpolated names, so the substring
    /// mode is what reaches a control whose displayed text the caller cannot
    /// predict in full. The mode never applies to `--role`, which names a
    /// fixed vocabulary rather than app-authored text.
    public enum WaitAXMatchMode: String, Equatable, Sendable {
        case exact
        case contains
    }

    /// Which way round `wait ax` reads its query.
    ///
    /// `absent` is the assertion a verification step actually needs: the
    /// spinner went, the error banner cleared, the sheet dismissed. Without
    /// it the only expression of absence is a `present` wait timing out,
    /// which conflates gone with never-looked-long-enough and with an
    /// observation that failed.
    ///
    /// Valued rather than a bare `--absent` switch for the same parser reason
    /// as `--print`: a presence-only flag arrives as a positional and would
    /// weaken `wait ax`'s exact-arity guard.
    public enum WaitAXState: String, Equatable, Sendable {
        case present
        case absent
    }

    /// What `wait ax` writes to stdout instead of its usual receipt line.
    ///
    /// Valued rather than a bare `--center` switch because the parser only
    /// recognizes value-taking flags; a presence-only flag arrives as a
    /// positional and would weaken `wait ax`'s exact-arity guard.
    public enum WaitAXPrint: String, Equatable, Sendable {
        case center
    }

    public struct WaitAXQuery: Equatable, Sendable {
        public let identifier: String?
        public let label: String?
        public let role: String?
        /// Optional filter on the element's own `value`, never a selector of
        /// its own. It narrows an element already named by `identifier` or
        /// `label`, which is what lets a caller assert that the field it
        /// identified now reads a particular string.
        public let value: String?
        public let matchMode: WaitAXMatchMode
        public let source: WaitAXSource
        public let step: Double?
        public let budgetMs: Int?

        public init(
            identifier: String?,
            label: String?,
            role: String?,
            value: String?,
            matchMode: WaitAXMatchMode,
            source: WaitAXSource,
            step: Double?,
            budgetMs: Int?
        ) {
            self.identifier = identifier
            self.label = label
            self.role = role
            self.value = value
            self.matchMode = matchMode
            self.source = source
            self.step = step
            self.budgetMs = budgetMs
        }
    }
}
