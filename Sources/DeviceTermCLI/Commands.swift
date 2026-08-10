// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure-logic CLI surface: argv parsing and request encoding.
//
// Kept separate from main.swift so Tests/CLITests can drive these
// functions directly. main.swift owns side effects (env reads, stderr,
// socket I/O, `exit`); this file owns the deterministic pieces.
//
// Grammar (locked): required operands are positional, optional modifiers
// are flags, and `--pane <ref>` is the shared targeting selector that
// picks among the session's device panes. A `<ref>` resolves a shortId,
// name, pane UUID prefix, sim UDID, or physical deviceId (omit it when
// the session owns a single device pane).
// `--duration <ms>` and `--velocity <v>` are the only other flags.

import DaemonProtocol
import Foundation

/// What an argv dispatches to. Pure: no I/O, no env. Tests assert on
/// this enum to pin dispatch behavior without spawning a process. The
/// `pane` on each pane-targeted case is the optional targeting ref
/// (from `--pane`); main.swift resolves it to a concrete paneId via
/// `panes.list` + `PaneRefResolver`.
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
        orientation: Orientation
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
        step: Double?
        )
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
    /// `deviceterm pane rename [--pane <ref>] [<name>]`: placeholder
    /// for the linkage refinement; daemon returns
    /// `intent.internalError` until pane rename lands alongside
    /// multi-terminal-pane.
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
    /// `deviceterm pane move [--pane <ref>] --to-tab <ref>`:
    /// placeholder; daemon returns `intent.internalError` until
    /// linkage-mutation lands.
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
    /// Idempotent when the device is already attached to the same tab;
    /// latest-attach-wins moves it from another tab. Supersedes the
    /// retired `pane attach` subverb.
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
    /// origin, filtering out windows that hold only foreign-private
    /// tabs). `--all` is not role-gated: any caller can widen the scope.
    case windowsList(
        all:
        Bool
        )
    /// `deviceterm tab send-input [--tab <ref>] [--type-delay <ms>]
    /// <text>`: write text into the resolved tab's terminal as
    /// though the user had typed it. Authorized by a live orchestration
    /// grant, not a role; a caller without a grant is rejected at the
    /// dispatcher's scope check with `error.role_violation`. `typeDelay`,
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
    /// orchestration grant, not a role. Human mode emits the raw text;
    /// `--json` emits a `{text}` object (`TabCapturePayload`).
    case tabCapture(
        tab:
        Wire.TabRef
        )
    /// `deviceterm tab set-private <true|false> [--tab <ref>]`:
    /// toggle the resolved tab's privacy flag. Defaults to the
    /// caller's tab. Owner-only on the daemon side (cap-validated);
    /// orchestrator can't flip another tab's privacy bit.
    case tabSetPrivate(
        tab:
        Wire.TabRef,
        isPrivate: Bool
        )

    /// Anything else: caller prints usage to stderr and exits 1.
    case usage(
        message:
        String?
        )
}

public enum CLICommands {
    // MARK: - Nested types

    /// Positionals and `--key value` / `--key=value` flags split out of
    /// an argument slice. Returns nil if a `--key` is missing its value.
    struct ParsedArgs: Equatable {
        var positionals: [String]
        var flags: [String: String]
    }

    // Request bodies are the shared `DaemonProtocol` param types
    // (`TapParams`, `SwipeParams`, `AXPointParams`, `PanesListParams`, …),
    // the exact shapes the daemon handlers decode, defined once. The
    // request builders below construct them directly; optional fields
    // encode as absent when nil (synthesized `encodeIfPresent`), so the
    // daemon applies its defaults.

    // MARK: - Parsing

    /// Top-level help triggers: `--help`, `-h`, and bare `help`.
    /// Detected in the verb position only so sub-command literals
    /// (`deviceterm text --help` typing the string "--help") stay
    /// untouched.
    static let helpTriggers: Set<String> = ["--help", "-h", "help"]

    /// Refusal text for `deviceterm help --all`. `--all` is not a help
    /// flag: the command list already names every verb, so there is
    /// nothing for it to reveal. Named explicitly rather than left to
    /// fall through as an ignored token, so a caller expecting a full
    /// dump is pointed at the reference instead of receiving the
    /// overview and believing it is everything.
    static let allFlagRejectedMessage = """
    deviceterm: help takes no --all flag. `deviceterm help` lists every
    command, and `deviceterm help <command>` reads one in full.
    """

    /// The literal output-mode toggle. Detected globally before
    /// dispatch so every verb supports it without per-verb wiring.
    static let jsonFlag = "--json"

    /// The exec-wrapper verbs whose post-verb tail is the child's argv,
    /// not deviceterm's: `with-pane`.
    static let execWrapperVerbs: Set<String> = ["with-pane"]

    /// Map a child `Process`'s termination status to an exec-like
    /// exit code. When the child was killed by a signal,
    /// follow the shell convention of `128 + signum` (SIGTERM=15 →
    /// 143, SIGINT=2 → 130) so wrapping scripts can distinguish
    /// an orderly `exit 15` from a signaled termination.
    public static func mapChildExitCode(
        status: Int32,
        reason: Process.TerminationReason
    ) -> Int32 {
        if reason == .uncaughtSignal {
            return 128 &+ status
        }
        return status
    }

    /// Flag names that consume a value, **scoped to the command**. Only
    /// these are parsed as flags; any other `--token` becomes a positional
    /// (so `text` can type literal `--`-prefixed words), and a bare `--`
    /// forces everything after it literal. Scoping per command means
    /// `--duration` / `--velocity` are literal text for commands that
    /// don't accept them, rather than being eaten as flags.
    ///
    /// Sourced from the shared `VerbCatalog` so the parser's flag grammar
    /// and the shell completions can't drift apart.
    static func valuedFlags(for verb: String) -> Set<String> {
        VerbCatalog.valuedFlags(for: verb)
    }

    // MARK: - Workspace ref parsing
    //
    // `parseTabRef` / `parsePaneRef` / `parseWindowRef` map a raw
    // `--tab` / `--pane` / `--window` value to the wire enum the
    // daemon's `IntentResolver` consumes. Discrimination rules:
    //   - Empty/nil/`current` → `.current`.
    //   - UUID → `.sessionId` (tab) / `.paneId` (pane).
    //   - Short alphanumeric (≤ 12 chars) → `.shortId`.
    //   - Anything else → `.name` (tab only) or `.shortId` (pane).
    //   - Pure integer (window) → `.index`.
    //   - Anything else (window) → `.keyed` (rejected by the
    //     resolver, but the encoding is forward-compatible).

    /// Convert a `--tab <ref>` value to the wire enum. Nil/empty
    /// means "current". Tests pin the discrimination rules so a
    /// future change has to update the assertion list.
    public static func parseTabRef(_ raw: String?) -> Wire.TabRef {
        guard let raw, !raw.isEmpty, raw != "current" else {
            return Wire.TabRef(type: "current", value: nil)
        }
        if UUID(uuidString: raw) != nil {
            return Wire.TabRef(type: "sessionId", value: raw)
        }
        if raw.count <= 12, raw.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return Wire.TabRef(type: "shortId", value: raw)
        }
        return Wire.TabRef(type: "name", value: raw)
    }

    /// Convert a `--pane <ref>` value to the wire enum. `--pane`
    /// accepts a paneId (UUID-shaped) or shortId here; name/UDID
    /// resolution happens against `panes.list`.
    public static func parsePaneRef(_ raw: String?) -> Wire.PaneRef {
        guard let raw, !raw.isEmpty, raw != "current" else {
            return Wire.PaneRef(type: "current", value: nil)
        }
        if UUID(uuidString: raw) != nil {
            return Wire.PaneRef(type: "paneId", value: raw)
        }
        return Wire.PaneRef(type: "shortId", value: raw)
    }

    /// Convert a `--window <ref>` value to the wire enum. Pure
    /// integers become a 1-based index; non-empty non-integer
    /// strings encode as `keyed` (forward-compat, the resolver
    /// rejects them, but the encoding shape is stable).
    public static func parseWindowRef(_ raw: String?) -> Wire.WindowRef {
        guard let raw, !raw.isEmpty, raw != "current" else {
            return Wire.WindowRef(type: "current", value: nil)
        }
        if Int(raw) != nil {
            return Wire.WindowRef(type: "index", value: raw)
        }
        return Wire.WindowRef(type: "keyed", value: raw)
    }

    /// Normalize a `--mode` flag to the wire-form `"detach"` /
    /// `"shutdown"` string. Anything else (including nil) is
    /// silently `detach`, matching the daemon's default and the
    /// per-tab close prompt's safest answer.
    public static func parseCloseMode(_ raw: String?) -> String {
        switch raw {
        case "shutdown":
            return "shutdown"

        default:
            return "detach"
        }
    }

    /// Decode C-style escape sequences in `raw` to the actual control
    /// bytes: `\n` → LF, `\r` → CR, `\t` → TAB, `\xNN` →
    /// arbitrary byte, etc. Used by `tab send-input` so the help-
    /// text examples (`'echo hi\\n'`) drive the shell as
    /// documented; without this the shell would receive a literal
    /// backslash + `n` because POSIX shells pass single-quoted
    /// argv through unchanged.
    ///
    /// Unknown / malformed escapes (`\z`, `\x`, `\x0`) preserve
    /// the literal `\` and the following character(s) so the
    /// output is never a silent lie. A dangling backslash at end
    /// of string is also preserved literally.
    ///
    /// Supported escapes match the bash $'…' / C-string set:
    ///   `\n` `\r` `\t` `\\` `\0` `\a` `\b` `\f` `\v` `\e`
    ///   `\xNN` (two hex digits, case-insensitive)
    public static func decodeEscapes(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var index = raw.startIndex
        while index < raw.endIndex {
            let char = raw[index]
            guard char == "\\" else {
                out.append(char)
                index = raw.index(after: index)
                continue
            }
            let afterBackslash = raw.index(after: index)
            guard afterBackslash < raw.endIndex else {
                // Dangling backslash. Preserve literally.
                out.append("\\")
                index = afterBackslash
                continue
            }
            let next = raw[afterBackslash]
            switch next {
            case "n":
                out.append("\n")

            case "r":
                out.append("\r")

            case "t":
                out.append("\t")

            case "\\":
                out.append("\\")

            case "0":
                out.append("\0")

            case "a":
                out.append("\u{07}")

            case "b":
                out.append("\u{08}")

            case "f":
                out.append("\u{0C}")

            case "v":
                out.append("\u{0B}")

            case "e":
                out.append("\u{1B}")

            case "x":
                let hexStart = raw.index(after: afterBackslash)
                let hexEnd = hexStart < raw.endIndex
                    ? raw.index(hexStart, offsetBy: 2, limitedBy: raw.endIndex)
                    : nil
                if let hexEnd,
                    hexEnd > hexStart,
                    raw.distance(from: hexStart, to: hexEnd) == 2,
                    let value = UInt8(raw[hexStart..<hexEnd], radix: 16) {
                    out.append(Character(Unicode.Scalar(value)))
                    // Jump past the `x` AND both hex digits.
                    index = hexEnd
                    continue
                }
                // Malformed `\x…`. Preserve literally.
                out.append("\\")
                out.append(next)

            default:
                // Unknown escape. Preserve both chars literally.
                out.append("\\")
                out.append(next)
            }
            index = raw.index(after: afterBackslash)
        }
        return out
    }

    /// Human-readable echo for a TabRef (used in `ok` lines /
    /// receipts). The wire keeps `(type, value)`; the echo flattens
    /// to either the literal value or the placeholder `current`.
    public static func echoLabel(_ ref: Wire.TabRef) -> String {
        if ref.type == "current" { return "current" }
        return ref.value ?? ref.type
    }

    /// Human-readable echo for a PaneRef.
    public static func echoLabel(_ ref: Wire.PaneRef) -> String {
        if ref.type == "current" { return "current" }
        return ref.value ?? ref.type
    }

    /// Human-readable echo for a WindowRef.
    public static func echoLabel(_ ref: Wire.WindowRef) -> String {
        if ref.type == "current" { return "current" }
        return ref.value ?? ref.type
    }

    static func splitFlags(_ args: [String], valued: Set<String>) -> ParsedArgs? {
        var positionals: [String] = []
        var flags: [String: String] = [:]
        var index = 0
        var literalOnly = false
        while index < args.count {
            let arg = args[index]
            if literalOnly {
                positionals.append(arg)
                index += 1
                continue
            }
            if arg == "--" {  // terminator: everything after is literal
                literalOnly = true
                index += 1
                continue
            }
            if arg.hasPrefix("--") {
                let body = String(arg.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    let name = String(body[..<equals])
                    if valued.contains(name) {
                        flags[name] = String(body[body.index(after: equals)...])
                        index += 1
                        continue
                    }
                } else if valued.contains(body) {
                    guard index + 1 < args.count else { return nil }
                    flags[body] = args[index + 1]
                    index += 2
                    continue
                }
                // Unknown / not-for-this-command `--token` falls through to
                // a positional, so `text` can type it literally.
            }
            positionals.append(arg)
            index += 1
        }
        return ParsedArgs(positionals: positionals, flags: flags)
    }

    /// Detect the requested output mode. `--json` anywhere in argv
    /// before a bare `--` terminator switches to JSON; tokens after
    /// `--` are literal (so `deviceterm text -- --json` types the
    /// literal string and stays in human mode). Detection is
    /// order-independent and works before `parse(_:)` strips the
    /// flag. Both surfaces use the same predicate so they can't
    /// drift.
    ///
    /// `with-pane` ignores `--json` in its post-verb tail. The tail
    /// is the child's argv, not deviceterm's. `--json` in
    /// the *prefix* (`deviceterm --json with-pane …`) still counts as
    /// the deviceterm-side flag (though with-pane doesn't emit its own
    /// output, so the practical effect is nil); the contract is
    /// "the strip and outputMode agree on what's pre-verb vs.
    /// child-owned."
    public static func outputMode(for argv: [String]) -> OutputMode {
        if let verbIdx = execWrapperVerbIndex(in: argv) {
            return argv.prefix(through: verbIdx).contains(jsonFlag) ? .json : .human
        }
        let endIndex = argv.firstIndex(of: "--") ?? argv.endIndex
        return argv[..<endIndex].contains(jsonFlag) ? .json : .human
    }

    /// Strip `--json` while preserving `deviceterm with-pane`'s child
    /// argv. When `with-pane` appears as a verb anywhere in argv
    /// (whether at position 1 or after global flags like
    /// `deviceterm --json with-pane …`), the strip applies only to the
    /// prefix through the verb itself. Everything after the verb
    /// is the child command's argv, including any `--json` the
    /// child needs.
    static func stripJSONFlagRespectingWithPane(_ argv: [String]) -> [String] {
        // The strip's normal "literal-after-`--`" behavior is
        // independent of the exec wrapper; both rules compose.
        guard let verbIdx = execWrapperVerbIndex(in: argv) else {
            return stripJSONFlag(argv)
        }
        let prefix = Array(argv.prefix(through: verbIdx))
        let strippedPrefix = stripJSONFlag(prefix)
        let tail = Array(argv.dropFirst(verbIdx + 1))
        return strippedPrefix + tail
    }

    /// Locate the `with-pane` exec-wrapper verb in argv.
    /// Tokens before the verb may be the binary path (`argv[0]`) plus
    /// global flags (`--json`, `--`); the first non-flag-or-binary
    /// token IS the verb position, and we only return a hit when that
    /// verb is one of `execWrapperVerbs`. Returns nil otherwise
    /// (callers fall back to the normal strip).
    private static func execWrapperVerbIndex(in argv: [String]) -> Int? {
        var index = 1
        while index < argv.count {
            let token = argv[index]
            // Skip global flags only: `--json` is the only one;
            // any future global flag is added here. Anything else
            // is a positional, which must be the verb.
            if token == jsonFlag {
                index += 1
                continue
            }
            // Bare `--` terminator before the verb: there's no
            // verb to find, the exec wrapper can't legally come after.
            if token == "--" { return nil }
            return execWrapperVerbs.contains(token) ? index : nil
        }
        return nil
    }

    /// Strip the global `--json` token from argv before the verb
    /// dispatcher sees it. Respects the `--` terminator so that
    /// `text` literals containing the string `--json` stay intact.
    static func stripJSONFlag(_ argv: [String]) -> [String] {
        var stripped: [String] = []
        stripped.reserveCapacity(argv.count)
        var literalOnly = false
        for arg in argv {
            if literalOnly {
                stripped.append(arg)
                continue
            }
            if arg == "--" {
                literalOnly = true
                stripped.append(arg)
                continue
            }
            if arg == jsonFlag { continue }
            stripped.append(arg)
        }
        return stripped
    }

    /// Parse a `deviceterm key <keyCode>` token. Accepts decimal
    /// (e.g. `48`) and `0x`-prefixed hex (e.g. `0x30`, Apple's
    /// canonical HIToolbox `kVK_*` presentation). Returns nil for
    /// negative, empty, or malformed tokens.
    static func parseKVKToken(_ token: String) -> UInt32? {
        let lowered = token.lowercased()
        if lowered.hasPrefix("0x") {
            return UInt32(lowered.dropFirst(2), radix: 16)
        }
        return UInt32(token)
    }

    /// Accept multiple spellings of a `RawValue == String` enum
    /// case typed at the command line. The wire enum uses Swift
    /// camelCase (`landscapeRight`, `applePay`, `digitalCrown`,
    /// `portraitUpsideDown`), which is awkward to type. Users
    /// reach for kebab-case (`landscape-right`), snake_case
    /// (`landscape_right`), all-lowercase (`landscaperight`), or
    /// mixed-case (`LandScapeRight`) by reflex. Normalize each of
    /// those to a camelCase candidate, then fall back to a
    /// case-insensitive scan of `allCases` so any equivalent
    /// spelling resolves to the same wire value. The wire enum
    /// itself doesn't change: this is parse-time normalization.
    static func parseEnumArg<T: RawRepresentable & CaseIterable>(
        _ raw: String,
        as type: T.Type
    ) -> T? where T.RawValue == String {
        // Fast path: exact camelCase match.
        if let direct = T(rawValue: raw) { return direct }
        // kebab / snake → camelCase.
        let parts = raw.split(whereSeparator: { $0 == "-" || $0 == "_" })
        if parts.count > 1 {
            let head = parts[0].lowercased()
            let tail = parts.dropFirst().map {
                $0.prefix(1).uppercased() + $0.dropFirst().lowercased()
            }
            let camel = ([head] + tail).joined()
            if let direct = T(rawValue: camel) { return direct }
        }
        // Last resort: case-insensitive scan. Catches all-
        // lowercase + arbitrary capitalization mixes.
        let lower = raw.lowercased()
        return T.allCases.first { $0.rawValue.lowercased() == lower }
    }

    /// Map the program's argv to a dispatch case. `argv[0]` is the
    /// binary path; meaningful args start at `argv[1]`.
    ///
    /// The `--json` token is stripped before the verb dispatcher
    /// runs so a positional-arity check like `tap <x> <y>` doesn't
    /// see an extra positional. Use `outputMode(for:)` on the
    /// original argv to read the requested presentation mode.
    ///
    /// `deviceterm with-pane` carves out the tail after its verb as the
    /// child command's argv (which is not deviceterm's to parse). The
    /// strip applies only to the *prefix through the verb* so the
    /// child sees its own flags (including `--json`) literally.
    /// Works whether with-pane is at `argv[1]` (no global flags) or
    /// later (`deviceterm --json with-pane …`).
    public static func parse(_ argv: [String]) -> CLICommand {
        let argv = stripJSONFlagRespectingWithPane(argv)
        guard argv.count >= 2 else { return .usage(message: nil) }
        let verb = argv[1]
        // Top-level help trigger fires before flag-splitting so
        // `--help` in the verb position doesn't have to be a
        // recognized flag of any command.
        if helpTriggers.contains(verb) {
            // The tail is read here rather than through the global flag
            // machinery, which never runs for a help trigger. The first
            // non-flag token names a topic; everything after it is
            // ignored, so `deviceterm help tap 0.5 0.5` lands on the tap
            // page and `deviceterm help windows list --all` on the
            // windows page. All three spellings behave alike; having
            // `--help crown` differ from `help crown` would be a trap.
            let tail = argv.dropFirst(2)
            guard let topic = tail.first(where: { !$0.hasPrefix("-") }) else {
                // No topic named, so nothing outranks a stray flag. A
                // bare `--all` here is the muscle-memory request for a
                // full dump; naming it beats ignoring it, which would
                // hand back the command list and let the caller believe
                // it is everything.
                if tail.contains("--all") {
                    return .usage(message: allFlagRejectedMessage)
                }
                return .help(topic: nil)
            }
            return .help(topic: topic)
        }
        // `deviceterm agents` is the long-form workflow guide. Dispatched
        // before flag-splitting since trailing args are tolerated
        // (the guide is one document; extra args don't change it).
        if verb == "agents" { return .agents }
        if verb == "doctor" { return .doctor }
        if verb == "events" { return .events }
        if verb == "version" { return .version }
        if verb == "dump-config" { return .dumpConfig }
        if verb == "completions" {
            // argv: ["deviceterm", "completions", "install", "<shell>"]
            // `install` is the only sub-verb; a print-only
            // `deviceterm completions <shell>` variant would land here
            // too. Reject other sub-verbs with a
            // pointing usage error rather than silently passing.
            guard argv.count == 4, argv[2] == "install",
                let shell = Completions.Shell(rawValue: argv[3])
            else {
                return .usage(
                    message:
                    "usage: deviceterm completions install <zsh|bash|fish>"
                    )
            }
            return .completionsInstall(shell: shell)
        }
        if execWrapperVerbs.contains(verb) {
            // argv: ["deviceterm", "with-pane", "<ref>", "<cmd>", "<args>"...]
            // First positional is the pane ref; everything after is the
            // child's argv (literal, preserved through the `--json`
            // strip above).
            guard argv.count >= 4 else {
                return .usage(
                    message:
                    "usage: deviceterm with-pane <ref> <cmd> [args...]"
                    )
            }
            let ref = argv[2]
            let cmd = Array(argv.dropFirst(3))
            return .withPane(ref: ref, cmd: cmd)
        }
        guard let parsed = splitFlags(Array(argv.dropFirst(2)), valued: valuedFlags(for: verb)) else {
            return .usage(message: "deviceterm: a flag is missing its value")
        }
        let pos = parsed.positionals
        // `--pane <ref>` is the universal targeting selector.
        let pane = parsed.flags["pane"]

        // Shared numeric flags, validated once. A present-but-malformed
        // flag is a usage error rather than a silently-dropped value.
        if let raw = parsed.flags["duration"], Int(raw) == nil {
            return .usage(message: "deviceterm: --duration must be an integer (ms)")
        }
        if let raw = parsed.flags["velocity"], Double(raw) == nil {
            return .usage(message: "deviceterm: --velocity must be a number")
        }
        if let raw = parsed.flags["hold"], Int(raw) == nil {
            return .usage(message: "deviceterm: --hold must be an integer (ms)")
        }
        if let raw = parsed.flags["step"], Double(raw) == nil {
            return .usage(message: "deviceterm: --step must be a number (normalized 0..1 fraction)")
        }
        let durationMs = parsed.flags["duration"].flatMap { Int($0) }
        let holdMs = parsed.flags["hold"].flatMap { Int($0) }
        let velocity = parsed.flags["velocity"].flatMap { Double($0) }
        let step = parsed.flags["step"].flatMap { Double($0) }

        switch verb {
        case "tabs":
            if pos == ["list"] { return .tabsList }
            if pos == ["current"] { return .tabsCurrent }
            return .usage(message: "deviceterm: 'tabs' supports: list, current")

        case "panes":
            guard pos == ["list"] else {
                return .usage(message: "deviceterm: 'panes' supports: list")
            }
            return .panesList

        case "devices":
            guard pos == ["list"] else {
                return .usage(message: "deviceterm: 'devices' supports: list")
            }
            return .devicesList

        case "device":
            return parseDeviceSubcommand(positionals: pos)

        case "tab":
            return parseTabSubcommand(positionals: pos, flags: parsed.flags)

        case "pane":
            return parsePaneSubcommand(positionals: pos, flags: parsed.flags)

        case "window":
            return parseWindowSubcommand(positionals: pos, flags: parsed.flags)

        case "windows":
            return parseWindowsSubcommand(positionals: pos)

        default:
            // Input-family verbs (tap … ax) live in `Commands+Input.swift`;
            // `parseInputVerb` returns nil for anything it doesn't own, so
            // an unrecognized verb falls through to the usage error.
            return parseInputVerb(
                verb,
                positionals: pos,
                pane: pane,
                durationMs: durationMs,
                holdMs: holdMs,
                velocity: velocity,
                step: step
            ) ?? .usage(message: nil)
        }
    }

    // MARK: - Request encoding

    // `internal` (not `private`) so the per-family request builders in
    // `Commands+Input.swift` / `Commands+Workspace.swift` can share it.
    static func request(method: RPCMethod, body: some Encodable) throws -> RPCEnvelope {
        let data = try JSONEncoder().encode(body)
        return RPCEnvelope(id: 1, type: .request, method: method.rawValue, body: .params(data))
    }
}
