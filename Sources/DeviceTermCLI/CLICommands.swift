// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Pure argv parsing and request encoding.
///
/// Kept separate from main.swift so Tests/CLITests can drive these
/// functions directly. main.swift owns side effects (env reads, stderr,
/// socket I/O, `exit`); this file owns the deterministic pieces.
///
/// The verb families split across `CLICommands+Workspace.swift` and
/// `CLICommands+Input.swift`; the grammar they share is documented on
/// `CLICommand`.
public enum CLICommands {
    // MARK: - Nested types

    /// Positionals and `--key value` / `--key=value` flags split out of
    /// an argument slice. Returns nil if a `--key` is missing its value.
    struct ParsedArgs: Equatable {
        var positionals: [String]
        var flags: [String: String]
        /// How many trailing positionals arrived after a `--` terminator
        /// and are therefore literal. Zero when no terminator appeared.
        /// The terminator itself is dropped, so this is the only record
        /// that a positional was escaped rather than typed bare.
        var escapedCount = 0
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

    /// The flag-shaped help triggers: `helpTriggers` minus bare `help`,
    /// which is excluded because a tab called that is ordinary. Derived
    /// rather than restated so a new spelling reaches both.
    /// See `isHelpRequest(nameTail:escapedCount:)`.
    static let helpFlags: Set<String> = helpTriggers.filter { $0.hasPrefix("-") }

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

    /// Whether a sub-verb's free-text tail is asking for the verb's shape
    /// rather than supplying a name. `splitFlags` leaves anything it
    /// doesn't recognize as a flag in the positionals so `text` can type
    /// it literally, which is what puts a help trigger in a name
    /// position; without this check `tab rename --help` renames the tab
    /// to "--help".
    ///
    /// True only for a lone `helpFlags` member that reached the tail
    /// unescaped. `escapedCount` keeps `--` meaning what it means
    /// everywhere else in the parser, and since the tail is the trailing
    /// run of positionals, a lone token is escaped exactly when that
    /// count is non-zero. Name-taking sub-verbs call this; the payload
    /// verbs (`text`, `tab send-input`) deliberately don't.
    static func isHelpRequest(nameTail tail: [String], escapedCount: Int) -> Bool {
        tail.count == 1 && escapedCount == 0 && helpFlags.contains(tail[0])
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
        // Where literal territory began, so a caller can still tell an
        // escaped positional from a bare one once the terminator is gone.
        var escapedFrom: Int?
        while index < args.count {
            let arg = args[index]
            if literalOnly {
                positionals.append(arg)
                index += 1
                continue
            }
            if arg == "--" {  // terminator: everything after is literal
                literalOnly = true
                escapedFrom = positionals.count
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
        return ParsedArgs(
            positionals: positionals,
            flags: flags,
            escapedCount: escapedFrom.map { positionals.count - $0 } ?? 0
        )
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
        if let raw = parsed.flags["budget"], Int(raw) == nil {
            return .usage(message: "deviceterm: --budget must be an integer (ms)")
        }
        let durationMs = parsed.flags["duration"].flatMap { Int($0) }
        let holdMs = parsed.flags["hold"].flatMap { Int($0) }
        let velocity = parsed.flags["velocity"].flatMap { Double($0) }
        let step = parsed.flags["step"].flatMap { Double($0) }
        let budgetMs = parsed.flags["budget"].flatMap { Int($0) }

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
            return parseTabSubcommand(
                positionals: pos,
                flags: parsed.flags,
                escapedCount: parsed.escapedCount
            )

        case "pane":
            return parsePaneSubcommand(
                positionals: pos,
                flags: parsed.flags,
                escapedCount: parsed.escapedCount
            )

        case "window":
            return parseWindowSubcommand(positionals: pos, flags: parsed.flags)

        case "windows":
            return parseWindowsSubcommand(positionals: pos)

        default:
            // Input-family verbs (tap … ax) live in `CLICommands+Input.swift`;
            // `parseInputVerb` returns nil for anything it doesn't own, so
            // an unrecognized verb falls through to the usage error.
            return parseInputVerb(
                verb,
                positionals: pos,
                pane: pane,
                durationMs: durationMs,
                holdMs: holdMs,
                velocity: velocity,
                step: step,
                budgetMs: budgetMs
            ) ?? .usage(message: nil)
        }
    }

    // MARK: - Request encoding

    // `internal` (not `private`) so the per-family request builders in
    // `CLICommands+Input.swift` / `CLICommands+Workspace.swift` can share it.
    static func request(method: RPCMethod, body: some Encodable) throws -> RPCEnvelope {
        let data = try JSONEncoder().encode(body)
        return RPCEnvelope(id: 1, type: .request, method: method.rawValue, body: .params(data))
    }
}
