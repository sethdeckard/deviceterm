// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Pure argv parsing and request encoding.
///
/// Free of side effects, so Tests/CLITests can drive these functions
/// directly; `CLIMain` owns env reads, stderr, socket I/O and `exit`.
///
/// `parse` is the one entry point, and it is total: every argv yields a
/// `CLICommand`, with failure carried in-band as `.usage`. The
/// `DeviceTerm` command tree owns the grammar, so `parse` hands argv to
/// `parseDeclared` after two carve-outs it cannot express: `help`, which
/// resolves its optional topic here and answers a bare trigger with an
/// overview the tree cannot produce, and `with-pane`, which must hand
/// its tail to a child process byte for byte. What remains in
/// `CLICommands+Workspace.swift` and `CLICommands+Input.swift` is the
/// request encoding and the checks a declaration cannot state.
public enum CLICommands {
    // Request bodies are the shared `DaemonProtocol` param types
    // (`TapParams`, `SwipeParams`, `AXPointParams`, `PanesListParams`, …),
    // the exact shapes the daemon handlers decode, defined once. The
    // request builders below construct them directly; optional fields
    // encode as absent when nil (synthesized `encodeIfPresent`), so the
    // daemon applies its defaults.

    // MARK: - Parsing

    /// Top-level help triggers: `--help`, `-h`, and bare `help`.
    ///
    /// Matched in the verb position, which is what reaches the overview
    /// and the concept pages. After a verb, a help trigger belongs to
    /// that verb's own parser: a declared verb answers it from the
    /// command tree, and the rest answer it themselves.
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

    /// Deadline the waiting verbs use when `--timeout` is omitted.
    static let defaultTimeoutMillis = 30_000

    /// Window of stillness `wait surface quiescent` uses when
    /// `--settle` is omitted.
    static let defaultSettleMillis = 500

    /// The refusal for a deadline that cannot elapse, or nil when the
    /// deadline is usable.
    ///
    /// Shared by every verb that takes `--timeout`, so a zero or
    /// negative one is refused wherever it appears rather than reaching
    /// dispatch as a deadline that has already passed. An omitted
    /// `--timeout` takes `defaultTimeoutMillis` and is always usable.
    static func timeoutRefusal(_ timeoutMs: Int?) -> CLICommand? {
        guard let timeoutMs, timeoutMs <= 0 else { return nil }
        return .usage(message: "deviceterm: --timeout must be greater than zero")
    }

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

    /// Decode C-style escape sequences in `raw` to the actual control
    /// bytes: `\n` → LF, `\r` → CR, `\t` → TAB, `\xNN` →
    /// arbitrary byte, etc. Used by `pane send-input` so the help-
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

    /// Detect the requested output mode. `--json` anywhere in argv
    /// before a bare `--` terminator switches to JSON; tokens after
    /// `--` are literal (so `deviceterm text -- --json` types the
    /// literal string and stays in human mode). AX commands are always
    /// JSON, including malformed invocations that parse as usage errors.
    /// Detection is order-independent and works before `parse(_:)`
    /// strips the flag. Both surfaces use the same predicate so they
    /// can't drift.
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
        let prefix = argv[..<endIndex]
        if prefix.contains(jsonFlag) { return .json }
        return prefix.dropFirst().first == "ax" ? .json : .human
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
            // machinery, which never runs for a help trigger. It resolves
            // through `helpTopic`, the same way a trailing `--help` does,
            // so `help tab show` and `tab show --help` reach one
            // page. Having the two spellings differ would be a trap.
            // Tokens past the resolved path are ignored, so
            // `deviceterm help tap 0.5 0.5` still lands on the tap page.
            let tail = Array(argv.dropFirst(2))
            guard let topic = helpTopic(in: tail) else {
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
        return parseDeclared(Array(argv.dropFirst()))
    }

    /// Parse a verb the `DeviceTerm` command tree owns.
    ///
    /// `arguments` excludes the program name, which `parseAsRoot`
    /// expects. Three outcomes: a command this CLI owns, which carries
    /// its own `CLICommand`; a help request, which arrives as a parsed
    /// value that is not one of ours because ArgumentParser answers
    /// `--help` with a type it does not export; or a thrown parse
    /// failure, which becomes the usage error the dispatcher already
    /// knows how to render in both human and JSON form.
    static func parseDeclared(_ arguments: [String]) -> CLICommand {
        do {
            let parsed = try DeviceTerm.parseAsRoot(CrownCommand.normalizing(arguments))
            guard let owned = parsed as? CLICommandConvertible else {
                return .help(topic: helpTopic(in: arguments))
            }
            return owned.cliCommand
        } catch {
            // A completion callback's candidates and a generated script
            // are thrown the same way a failure is, and only the exit
            // code tells them apart.
            guard DeviceTerm.exitCode(for: error) != .success else {
                return .cleanExit(text: DeviceTerm.message(for: error))
            }
            // The full form, not the bare diagnostic: it carries the
            // failing command's usage line, which is where a caller who
            // mistyped a sub-verb reads the ones that exist.
            let rendered = DeviceTerm.fullMessage(for: error)
            guard let hint = terminatorHint(
                forArguments: arguments,
                diagnostic: DeviceTerm.message(for: error)
            ) else { return .usage(message: rendered) }
            return .usage(message: rendered + "\n" + hint)
        }
    }

    /// The `--` cue for a free-text verb that refused a dashed word.
    ///
    /// Naming the token the parser rejected is not enough on a verb
    /// whose payload is arbitrary text, because the caller usually meant
    /// to send that token. Without the cue the refusal is a dead end;
    /// with it, it is a fix.
    static func terminatorHint(forArguments arguments: [String], diagnostic: String) -> String? {
        guard diagnostic.contains("Unknown option") else { return nil }
        let leading = Array(arguments.prefix { !$0.hasPrefix("-") })
        guard let command = CommandTree.command(for: CommandTree.longestCommandPath(in: leading)),
            command is any FreeTextCommand.Type else { return nil }
        return "Put -- before the text to type a word beginning with -."
    }

    /// The topic a help request is asking about.
    ///
    /// A declared verb resolves to the longest leading run of non-flag
    /// tokens that names a command path, so `tab show --help` and
    /// `help tab show` reach one page. A verb the command tree does
    /// not declare resolves to nothing, and the first non-flag token
    /// names the legacy topic instead.
    static func helpTopic(in arguments: [String]) -> String? {
        let leading = Array(arguments.prefix { !$0.hasPrefix("-") })
        let path = CommandTree.longestCommandPath(in: leading)
        if !path.isEmpty { return path.joined(separator: " ") }
        return arguments.first { !$0.hasPrefix("-") }
    }

    // MARK: - Request encoding

    // `internal` (not `private`) so the per-family request builders in
    // `CLICommands+Input.swift` / `CLICommands+Workspace.swift` can share it.
    static func request(method: RPCMethod, body: some Encodable) throws -> RPCEnvelope {
        let data = try JSONEncoder().encode(body)
        return RPCEnvelope(id: 1, type: .request, method: method.rawValue, body: .params(data))
    }
}
