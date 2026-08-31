// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// What an argv dispatches to. Pure: no I/O, no env. Tests assert on
/// this enum to pin dispatch behavior without spawning a process. The
/// `pane` on each pane-targeted case is the optional targeting ref
/// (from `--pane`); main.swift resolves it to a concrete paneId via
/// `panes.list` + `PaneRefResolver`.
///
/// Kept separate from main.swift so Tests/CLITests can drive the parse
/// directly. main.swift owns side effects (env reads, stderr, socket I/O,
/// `exit`); this enum is the deterministic result of reading argv.
///
/// Grammar (locked): required operands are positional, optional modifiers
/// are flags, and `--pane <ref>` is the shared targeting selector that
/// picks among the tab's device panes. A `<ref>` resolves a shortId,
/// name, pane UUID prefix, sim UDID, or physical deviceId (omit it when
/// the tab shows a single device pane). `--duration`, `--hold`,
/// `--velocity`, and `--step` are the input-specific modifiers.
public enum CLICommand: Equatable, Sendable {
    case tabsList
    /// `deviceterm tabs current`: print the caller's own tab row (the
    /// one whose `sessionId` matches `DEVICETERM_SESSION`). Exits
    /// non-zero when the env is unset or the matching row is missing
    /// from `tabs.list`.
    case tabsCurrent
    case panesList
    case tap(
        pane:
        String?,
        x: Double,
        y: Double
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
    case waitAX(pane: String?, query: WaitAXQuery, timeoutMs: Int)
    case waitOrientation(pane: String?, orientation: Orientation, timeoutMs: Int)
    /// Explicit help request: `deviceterm --help`, `deviceterm -h`, or
    /// `deviceterm help`. The command list and any known page write to
    /// stdout and exit 0; an unknown topic fails with suggestions.
    ///
    /// `topic` is the first non-flag token after the trigger
    /// (`deviceterm help crown`), nil for a bare trigger. It is not
    /// validated here. The dispatcher resolves it against `HelpCatalog`,
    /// which is what lets the unknown-topic error carry suggestions
    /// instead of collapsing into the terse usage block.
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

    /// `deviceterm tab open [--window <ref>] [--cwd <path>] [--cmd '<cmd>']`:
    /// mints a new agent-role tab in the chosen window (defaults
    /// to the caller's own window, not the human's key window). `--cwd`
    /// overrides the new shell's
    /// startup directory; `--cmd '<cmd>'` is typed into the shell
    /// after attach (libghostty's `initial_input`) so the command
    /// runs once and leaves the user at an interactive prompt.
    case tabOpen(
        window: Wire.WindowRef?,
        cwd: String? = nil,
        cmd: String? = nil
    )
    /// `deviceterm tab close [--tab <ref>] [--mode <detach|shutdown>]`:
    /// closes the named tab (default: caller's current tab) with
    /// the chosen close mode for any linked sims.
    case tabClose(
        tab:
        Wire.TabRef,
        mode: String
        )
    /// `deviceterm tab rename [--tab <ref>] [<name>]`: applies a
    /// manual title to the named tab. Omit the positional name to
    /// restore the automatic title (CWD / OSC / session name).
    case tabRename(
        tab:
        Wire.TabRef,
        name: String?
        )
    /// `deviceterm tab select [--tab <ref>]`: focus the named tab in
    /// its window.
    case tabSelect(
        tab:
        Wire.TabRef
        )
    /// `deviceterm tab info [--tab <ref>]`: print a structured
    /// description of the named tab (role, session, linked sim
    /// panes).
    case tabInfo(
        tab:
        Wire.TabRef
        )
    /// `deviceterm tab move [--tab <ref>] [--to <index>]
    /// [--to-window <ref>]`: reorder the named tab within its window
    /// (`--to`) or move it to another window (`--to-window`, optionally
    /// at `--to`). At least one of `--to` / `--to-window` is required.
    case tabMove(
        tab: Wire.TabRef,
        toIndex: Int?,
        toWindow: Wire.WindowRef?
        )
    /// `deviceterm pane open --terminal [--tab <ref>] [--cwd <path>]
    /// [--cmd '<cmd>']`: open a fresh terminal pane alongside the
    /// tab's existing panes, splitting the tab rather than opening a
    /// new one. `--cwd` and `--cmd '<cmd>'` semantics match
    /// `tab open`.
    case paneOpenTerminal(
        tab: Wire.TabRef?,
        cwd: String? = nil,
        cmd: String? = nil
    )
    /// `deviceterm pane close [--pane <ref>] [--mode <detach|shutdown>]`:
    /// detach or shut down the named sim pane.
    case paneClose(
        pane:
        Wire.PaneRef,
        mode: String
        )
    /// `deviceterm pane rename [--pane <ref>] [<name>]`: unsupported;
    /// the daemon returns `intent.internalError`.
    case paneRename(
        pane:
        Wire.PaneRef,
        name: String?
        )
    /// `deviceterm pane info [--pane <ref>]`: print a structured
    /// description of the named sim pane.
    case paneInfo(
        pane:
        Wire.PaneRef
        )
    /// `deviceterm pane move [--pane <ref>] --to-tab <ref>`: unsupported;
    /// the daemon returns `intent.internalError`.
    case paneMove(
        pane:
        Wire.PaneRef,
        toTab: Wire.TabRef
        )
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
    /// ownership state. Superset of `panes list`; backed by the
    /// session-scoped `devices.list` RPC. Not a `simctl list` clone.
    /// Never enumerates shutdown / never-booted sims.
    case devicesList
    /// `deviceterm window open`: mint a new window with one fresh
    /// agent-role tab.
    case windowOpen
    /// `deviceterm window close [--window <ref>] [--mode <detach|shutdown>]`:
    /// close the named window (default: the caller's own window, not
    /// the human's key window; refused if it also holds a tab the caller
    /// can't see).
    case windowClose(
        window:
        Wire.WindowRef,
        mode: String
        )
    /// `deviceterm window focus [--window <ref>]`: bring the named
    /// window forward.
    case windowFocus(
        window:
        Wire.WindowRef
        )
    /// `deviceterm windows list [--all]`: list the visible windows.
    /// Default scopes to the caller's window; `--all` returns every
    /// window the caller may see (the dispatcher scopes by the intent's
    /// origin, filtering out windows that hold only foreign-protected
    /// tabs). `--all` is not role-gated: any caller can widen the scope.
    case windowsList(
        all:
        Bool
        )
    /// `deviceterm tab send-input [--tab <ref>] [--type-delay <ms>]
    /// <text>`: write text into the resolved tab's terminal as
    /// though the user had typed it. Authorized by a live automation
    /// grant, not a role; a caller without a grant is rejected at the
    /// dispatcher's scope check with `error.scope_violation`. `typeDelay`,
    /// when positive, animates the injection one character at a time (for
    /// screencasts); `nil` = the instant one-shot.
    case tabSendInput(
        tab:
        Wire.TabRef,
        text: String,
        typeDelay: Int?
        )
    /// `deviceterm tab capture [--tab <ref>]`: print the resolved
    /// tab's currently-visible viewport to stdout. Authorized by a live
    /// automation grant, not a role. Human mode emits the raw text;
    /// `--json` emits a `{text}` object (`TabCapturePayload`).
    case tabCapture(
        tab:
        Wire.TabRef
        )
    /// `deviceterm tab set-protected <true|false> [--tab <ref>]`:
    /// toggle the resolved tab's protection flag. Defaults to the
    /// caller's tab. Owner-only through the GUI's origin gate; the
    /// underlying batch RPC is restricted to the validated GUI, and
    /// automation can't flip another tab's protection bit.
    case tabSetProtected(
        tab:
        Wire.TabRef,
        isProtected: Bool
        )

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
