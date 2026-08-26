// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

/// Parser surface for the tab / pane /
/// window / windows verbs.
///
/// Every verb gets a happy-path test that pins the exact `CLICommand`
/// the parser emits, plus malformed/usage tests for the verbs whose
/// usage messages were designed to point at the right shape. Covers
/// the standing parser-test invariant: "every verb's parse surface
/// gets happy + malformed coverage."
struct WorkspaceCommandsTests {
    // MARK: - Ref parsing

    /// Each row exercises one `parseTabRef` discrimination rule.
    private struct TabRefCase {
        let raw: String?
        let type: String
        let value: String?
    }

    /// Roster fixture for the `device attach` resolution tests.
    private static let attachRoster = [
        DeviceRosterEntry(
            id: "5E6F7A8B-PHONE-0000-0000-000000000000",
            kind: .sim,
            name: "iPhone 17 Pro",
            state: "Booted"
        ),
        DeviceRosterEntry(
            id: "fd00:1234::a1b2",
            kind: .device,
            name: "field-unit",
            state: "connected"
        )
    ]

    @Test
    func tabRefRoundTripDiscriminations() {
        let cases: [TabRefCase] = [
            TabRefCase(raw: nil, type: "current", value: nil),
            TabRefCase(raw: "", type: "current", value: nil),
            TabRefCase(raw: "current", type: "current", value: nil),
            TabRefCase(
                raw: "550E8400-E29B-41D4-A716-446655440000",
                type: "sessionId",
                value: "550E8400-E29B-41D4-A716-446655440000"
            ),
            TabRefCase(raw: "abc123", type: "shortId", value: "abc123"),
            TabRefCase(
                raw: "auth-feature",
                type: "name",
                value: "auth-feature"
            ),
            TabRefCase(
                raw: "With Spaces",
                type: "name",
                value: "With Spaces"
            )
        ]
        for testCase in cases {
            let ref = CLICommands.parseTabRef(testCase.raw)
            #expect(
                ref.type == testCase.type,
                "input=\(testCase.raw ?? "nil")"
                )
            #expect(
                ref.value == testCase.value,
                "input=\(testCase.raw ?? "nil")"
                )
        }
    }

    @Test
    func paneRefDistinguishesUUIDsFromShortIds() {
        let uuid = CLICommands.parsePaneRef(
            "550E8400-E29B-41D4-A716-446655440000"
        )
        #expect(uuid.type == "paneId")
        let short = CLICommands.parsePaneRef("ab12cd")
        #expect(short.type == "shortId")
        let current = CLICommands.parsePaneRef(nil)
        #expect(current.type == "current")
    }

    @Test
    func windowRefDistinguishesIndexFromKeyed() {
        let index = CLICommands.parseWindowRef("2")
        #expect(index.type == "index")
        #expect(index.value == "2")
        let keyed = CLICommands.parseWindowRef("main")
        #expect(keyed.type == "keyed")
        let current = CLICommands.parseWindowRef("current")
        #expect(current.type == "current")
    }

    @Test(
        arguments: [
        ("detach", "detach"),
        ("shutdown", "shutdown"),
        ("garbage", "detach"),
        // unknown falls back to safest
        (nil as String?, "detach")
        ]
        )
    func closeModeNormalization(raw: String?, expected: String) {
        #expect(CLICommands.parseCloseMode(raw) == expected)
    }

    // MARK: - Tab subcommands

    @Test
    func tabOpenBareDefaultsToCurrentWindow() {
        let cmd = CLICommands.parse(["deviceterm", "tab", "open"])
        if case let .tabOpen(window, cwd, cmdLine) = cmd {
            #expect(window == nil)  // omitted → no override at the parser layer
            #expect(cwd == nil)
            #expect(cmdLine == nil)
        } else {
            Issue.record("expected .tabOpen; got \(cmd)")
        }
    }

    @Test
    func tabOpenWithWindow() {
        let cmd = CLICommands.parse(
            ["deviceterm", "tab", "open", "--window", "2"]
        )
        if case let .tabOpen(window, _, _) = cmd {
            #expect(window?.type == "index")
            #expect(window?.value == "2")
        } else {
            Issue.record("expected .tabOpen; got \(cmd)")
        }
    }

    /// `--cwd` overrides the new shell's startup directory. Parser
    /// threads it onto `tabOpen`, the wire honors it via
    /// `OpenTab.cwd`, and the GUI sets it on libghostty's surface
    /// config.
    @Test
    func tabOpenAcceptsCwdFlag() {
        let cmd = CLICommands.parse(
            ["deviceterm", "tab", "open", "--cwd", "/proj"]
        )
        if case let .tabOpen(_, cwd, _) = cmd {
            #expect(cwd == "/proj")
        } else {
            Issue.record("expected .tabOpen; got \(cmd)")
        }
    }

    /// `--cmd '<cmd>'` is typed into the shell after attach. The
    /// CLI takes the value as a single string and the GUI joins on
    /// spaces (degenerate for single-string) before handing to
    /// libghostty's `initial_input`.
    @Test
    func tabOpenAcceptsCmdFlag() {
        let cmd = CLICommands.parse(
            ["deviceterm", "tab", "open", "--cmd", "claude --print"]
        )
        if case let .tabOpen(_, _, cmdLine) = cmd {
            #expect(cmdLine == "claude --print")
        } else {
            Issue.record("expected .tabOpen; got \(cmd)")
        }
    }

    @Test
    func tabOpenRejectsUnknownTail() {
        let cmd = CLICommands.parse(
            ["deviceterm", "tab", "open", "garbage-positional"]
        )
        if case .usage = cmd {
            // expected
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    @Test
    func tabMoveReordersWithinWindow() {
        let cmd = CLICommands.parse(["deviceterm", "tab", "move", "--to", "0"])
        if case let .tabMove(tab, toIndex, toWindow) = cmd {
            #expect(tab.type == "current")
            #expect(toIndex == 0)
            #expect(toWindow == nil)
        } else {
            Issue.record("expected .tabMove; got \(cmd)")
        }
    }

    @Test
    func tabMoveToAnotherWindow() {
        let cmd = CLICommands.parse(
            ["deviceterm", "tab", "move", "--tab", "ab12cd", "--to-window", "2", "--to", "1"]
        )
        if case let .tabMove(tab, toIndex, toWindow) = cmd {
            #expect(tab.type == "shortId")
            #expect(tab.value == "ab12cd")
            #expect(toWindow?.type == "index")
            #expect(toWindow?.value == "2")
            #expect(toIndex == 1)
        } else {
            Issue.record("expected .tabMove; got \(cmd)")
        }
    }

    @Test
    func tabMoveRequiresADestination() {
        let cmd = CLICommands.parse(["deviceterm", "tab", "move", "--tab", "ab12cd"])
        if case .usage = cmd {
            // expected: neither --to nor --to-window
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    @Test
    func tabMoveRejectsNonIntegerIndex() {
        let cmd = CLICommands.parse(["deviceterm", "tab", "move", "--to", "left"])
        if case .usage = cmd {
            // expected: --to must be an integer
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    @Test
    func tabMoveRejectsPositionalTail() {
        let cmd = CLICommands.parse(["deviceterm", "tab", "move", "0"])
        if case .usage = cmd {
            // expected: index goes on --to, not a positional
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    @Test
    func tabCloseDefaultsToCurrentAndDetach() {
        let cmd = CLICommands.parse(["deviceterm", "tab", "close"])
        if case let .tabClose(ref, mode) = cmd {
            #expect(ref.type == "current")
            #expect(mode == "detach")
        } else {
            Issue.record("expected .tabClose; got \(cmd)")
        }
    }

    @Test
    func tabCloseWithRefAndShutdownMode() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "tab",
            "close",
            "--tab",
            "abc123",
            "--mode",
            "shutdown"
            ]
            )
        if case let .tabClose(ref, mode) = cmd {
            #expect(ref.type == "shortId")
            #expect(ref.value == "abc123")
            #expect(mode == "shutdown")
        } else {
            Issue.record("expected .tabClose; got \(cmd)")
        }
    }

    @Test
    func tabRenameWithNamePositional() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "tab",
            "rename",
            "--tab",
            "auth",
            "feature-x"
            ]
            )
        if case let .tabRename(ref, name) = cmd {
            #expect(ref.value == "auth")
            #expect(name == "feature-x")
        } else {
            Issue.record("expected .tabRename; got \(cmd)")
        }
    }

    @Test
    func tabRenameWithoutNameRestoresAuto() {
        let cmd = CLICommands.parse(["deviceterm", "tab", "rename"])
        if case let .tabRename(_, name) = cmd {
            #expect(name == nil)
        } else {
            Issue.record("expected .tabRename; got \(cmd)")
        }
    }

    @Test
    func tabRenameJoinsMultiTokenNames() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "tab",
            "rename",
            "billing",
            "v2"
            ]
            )
        if case let .tabRename(_, name) = cmd {
            #expect(name == "billing v2")
        } else {
            Issue.record("expected .tabRename; got \(cmd)")
        }
    }

    @Test(arguments: ["--help", "-h"])
    func tabRenameHelpFlagIsUsage(trigger: String) {
        // The splitter leaves both triggers in the positional tail;
        // without the name-position guard, either would become the new
        // tab name.
        let cmd = CLICommands.parse(["deviceterm", "tab", "rename", trigger])
        if case .usage = cmd {
            // expected: print the shape rather than rename
        } else {
            Issue.record("expected .usage for '\(trigger)'; got \(cmd)")
        }
    }

    @Test(arguments: ["--help", "-h"])
    func tabRenameHelpFlagIsUsageWithTabFlag(trigger: String) {
        // The `--tab <ref>` selector consumes its value before the tail
        // is read, so the guard sees the same lone trigger either way.
        let cmd = CLICommands.parse(
            ["deviceterm", "tab", "rename", "--tab", "auth", trigger]
            )
        if case .usage = cmd {
            // expected: the selector doesn't change the tail's meaning
        } else {
            Issue.record("expected .usage for '\(trigger)'; got \(cmd)")
        }
    }

    @Test
    func tabRenameKeepsBareHelpAsName() {
        // `help` is a plausible tab name, so only the flag-shaped
        // triggers are treated as a request for the shape.
        let cmd = CLICommands.parse(["deviceterm", "tab", "rename", "help"])
        if case let .tabRename(_, name) = cmd {
            #expect(name == "help")
        } else {
            Issue.record("expected .tabRename; got \(cmd)")
        }
    }

    @Test(arguments: ["--help", "-h"])
    func tabRenameTerminatorForcesHelpFlagAsName(trigger: String) {
        // `--` means the same thing here as everywhere else in the
        // parser: what follows is literal. The terminator itself is
        // dropped, so the guard reads `escapedCount` to tell this apart
        // from the bare form.
        let cmd = CLICommands.parse(
            ["deviceterm", "tab", "rename", "--", trigger]
            )
        if case let .tabRename(_, name) = cmd {
            #expect(name == trigger)
        } else {
            Issue.record("expected .tabRename for '\(trigger)'; got \(cmd)")
        }
    }

    @Test
    func tabRenameKeepsHelpFlagInsideLongerName() {
        // Only a lone trigger is a help request; a longer tail stays the
        // literal multi-token name the join already produced.
        let cmd = CLICommands.parse(
            ["deviceterm", "tab", "rename", "sprint", "--help"]
            )
        if case let .tabRename(_, name) = cmd {
            #expect(name == "sprint --help")
        } else {
            Issue.record("expected .tabRename; got \(cmd)")
        }
    }

    @Test
    func tabSetProtectedAcceptsTrueAndFalse() {
        // Both the positive and negative forms parse cleanly; the
        // boolean lands as the second element of the
        // `.tabSetProtected` case.
        let onCmd = CLICommands.parse(["deviceterm", "tab", "set-protected", "true"])
        if case let .tabSetProtected(_, isProtected) = onCmd {
            #expect(isProtected == true)
        } else {
            Issue.record("expected .tabSetProtected; got \(onCmd)")
        }
        let offCmd = CLICommands.parse(["deviceterm", "tab", "set-protected", "false"])
        if case let .tabSetProtected(_, isProtected) = offCmd {
            #expect(isProtected == false)
        } else {
            Issue.record("expected .tabSetProtected; got \(offCmd)")
        }
    }

    @Test
    func tabSetProtectedAcceptsCommonSynonyms() {
        // The synonyms documented at parse time (yes/no, on/off,
        // 1/0) should all parse cleanly so an agent typing a
        // sloppy shorthand doesn't trip over the verb.
        let cases: [(String, Bool)] = [
            ("yes", true),
            ("no", false),
            ("on", true),
            ("off", false),
            ("1", true),
            ("0", false)
        ]
        for (raw, expected) in cases {
            let cmd = CLICommands.parse(
                ["deviceterm", "tab", "set-protected", raw]
            )
            if case let .tabSetProtected(_, isProtected) = cmd {
                #expect(isProtected == expected, "for raw=\(raw)")
            } else {
                Issue.record("expected .tabSetProtected for \(raw); got \(cmd)")
            }
        }
    }

    @Test
    func tabSetProtectedRejectsUnknownBoolean() {
        let cmd = CLICommands.parse(["deviceterm", "tab", "set-protected", "maybe"])
        if case .usage = cmd {
            // Expected: non-boolean tokens land at usage.
        } else {
            Issue.record("expected .usage for typo; got \(cmd)")
        }
    }

    @Test
    func tabSetProtectedRequiresPositional() {
        let cmd = CLICommands.parse(["deviceterm", "tab", "set-protected"])
        if case .usage = cmd {
            // Expected: the verb has no useful default for the bool.
        } else {
            Issue.record("expected .usage for missing positional; got \(cmd)")
        }
    }

    @Test
    func tabSetProtectedForwardsTabRef() {
        // `--tab <ref>` resolves to the wire-encoded ref; without
        // the flag the ref defaults to `.current`.
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "tab",
            "set-protected",
            "true",
            "--tab",
            "billing"
            ]
            )
        if case let .tabSetProtected(ref, _) = cmd {
            #expect(ref.value == "billing")
        } else {
            Issue.record("expected .tabSetProtected; got \(cmd)")
        }
    }

    @Test
    func tabSelect() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "tab",
            "select",
            "--tab",
            "abc123"
            ]
            )
        if case let .tabSelect(ref) = cmd {
            #expect(ref.type == "shortId")
        } else {
            Issue.record("expected .tabSelect; got \(cmd)")
        }
    }

    @Test
    func tabInfo() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "tab",
            "info",
            "--tab",
            "abc123"
            ]
            )
        if case let .tabInfo(ref) = cmd {
            #expect(ref.value == "abc123")
        } else {
            Issue.record("expected .tabInfo; got \(cmd)")
        }
    }

    @Test
    func tabUnknownSubcommandIsUsage() {
        let cmd = CLICommands.parse(["deviceterm", "tab", "make-tea"])
        if case .usage = cmd {
            // expected
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    // MARK: - tab send-input (automation-only)

    @Test
    func tabSendInputJoinsMultiTokenText() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "tab",
            "send-input",
            "--tab",
            "abc123",
            "echo",
            "hi"
            ]
            )
        if case let .tabSendInput(ref, text, typeDelay) = cmd {
            #expect(ref.type == "shortId")
            #expect(ref.value == "abc123")
            #expect(text == "echo hi")
            #expect(typeDelay == nil)
        } else {
            Issue.record("expected .tabSendInput; got \(cmd)")
        }
    }

    @Test
    func tabSendInputDecodesEscapeSequences() {
        // Documented example: deviceterm tab send-input 'echo hi\n'.
        // POSIX shells pass `echo hi\n` (literal backslash + n)
        // through; the parser must decode to the actual LF byte
        // so the shell sees Enter.
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "tab",
            "send-input",
            "echo hi\\n"
            ]
            )
        if case let .tabSendInput(_, text, _) = cmd {
            #expect(text == "echo hi\n")
        } else {
            Issue.record("expected .tabSendInput; got \(cmd)")
        }
    }

    @Test(
        arguments: [
        ("\\n", "\n"),
        ("\\r", "\r"),
        ("\\t", "\t"),
        ("\\\\", "\\"),
        ("\\0", "\0"),
        ("\\e", "\u{1B}"),
        ("\\x03", "\u{03}"),
        ("\\x7F", "\u{7F}"),
        ("hello\\nworld", "hello\nworld")
        ]
        )
    func decodeEscapesHonorsCStyleSet(raw: String, expected: String) {
        #expect(CLICommands.decodeEscapes(raw) == expected)
    }

    @Test
    func decodeEscapesPreservesUnknownAndDangling() {
        // Unknown escape: \z stays as `\z` rather than silently
        // dropping the backslash.
        #expect(CLICommands.decodeEscapes("\\z") == "\\z")
        // Dangling backslash at EOL preserves literally.
        #expect(CLICommands.decodeEscapes("end\\") == "end\\")
        // Malformed \x (no hex pair) preserves literally.
        #expect(CLICommands.decodeEscapes("\\x") == "\\x")
    }

    @Test
    func tabSendInputDefaultsToCurrentTab() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "tab",
            "send-input",
            "ping"
            ]
            )
        if case let .tabSendInput(ref, text, typeDelay) = cmd {
            #expect(ref.type == "current")
            #expect(text == "ping")
            #expect(typeDelay == nil)
        } else {
            Issue.record("expected .tabSendInput; got \(cmd)")
        }
    }

    @Test
    func tabSendInputRejectsEmptyText() {
        let cmd = CLICommands.parse(["deviceterm", "tab", "send-input"])
        if case .usage = cmd {
            // expected: no text is a usage error
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    @Test(arguments: ["--help", "-h"])
    func tabSendInputKeepsHelpFlagAsText(trigger: String) {
        // Typing an arbitrary string is what this verb is for, so its
        // tail is a payload and a help trigger in it is literal, the
        // same contract `text` keeps. The name-position guard that
        // `tab rename` uses deliberately does not apply here.
        let cmd = CLICommands.parse(
            ["deviceterm", "tab", "send-input", trigger]
            )
        if case let .tabSendInput(_, text, _) = cmd {
            #expect(text == trigger)
        } else {
            Issue.record("expected .tabSendInput for '\(trigger)'; got \(cmd)")
        }
    }

    @Test
    func tabSendInputParsesTypeDelay() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "tab",
            "send-input",
            "--type-delay",
            "45",
            "--",
            "echo hi\\n"
            ]
            )
        if case let .tabSendInput(_, text, typeDelay) = cmd {
            #expect(text == "echo hi\n")
            #expect(typeDelay == 45)
        } else {
            Issue.record("expected .tabSendInput; got \(cmd)")
        }
    }

    @Test
    func tabSendInputAcceptsZeroTypeDelay() {
        let cmd = CLICommands.parse(
            ["deviceterm", "tab", "send-input", "--type-delay", "0", "ping"]
            )
        if case let .tabSendInput(_, _, typeDelay) = cmd {
            #expect(typeDelay == 0)
        } else {
            Issue.record("expected .tabSendInput; got \(cmd)")
        }
    }

    @Test(arguments: ["abc", "-5", "4.5", ""])
    func tabSendInputRejectsMalformedTypeDelay(raw: String) {
        let cmd = CLICommands.parse(
            ["deviceterm", "tab", "send-input", "--type-delay", raw, "ping"]
            )
        if case .usage = cmd {
            // expected: a non-negative integer is required
        } else {
            Issue.record("expected .usage for --type-delay '\(raw)'; got \(cmd)")
        }
    }

    @Test
    func tabSendInputCapsHugeTypeDelay() {
        // A parse-time cap keeps the wire value bounded so no
        // downstream arithmetic overflows (e.g. Int.max × text.count).
        let cmd = CLICommands.parse(
            [
            "deviceterm", "tab", "send-input",
            "--type-delay", String(Int.max),
            "ping"
            ]
            )
        if case let .tabSendInput(_, _, typeDelay) = cmd {
            #expect(typeDelay == CLICommands.maxTypeDelayMillis)
        } else {
            Issue.record("expected .tabSendInput; got \(cmd)")
        }
    }

    @Test
    func tabSendInputRequestEncodesParams() throws {
        let envelope = try CLICommands.tabSendInputRequest(
            tab: Wire.TabRef(type: "sessionId", value: "S-A"),
            text: "hello"
        )
        #expect(envelope.method == RPCMethod.tabSendInput.rawValue)
        guard case let .params(data) = envelope.body else {
            Issue.record("expected .params body"); return
        }
        let decoded = try JSONDecoder().decode(
            AppCommandParams.TabSendInput.self,
            from: data
        )
        #expect(decoded.tab.type == "sessionId")
        #expect(decoded.tab.value == "S-A")
        #expect(decoded.text == "hello")
        #expect(decoded.typeDelayMillis == nil)
    }

    @Test
    func tabSendInputRequestEncodesTypeDelay() throws {
        let envelope = try CLICommands.tabSendInputRequest(
            tab: Wire.TabRef(type: "sessionId", value: "S-A"),
            text: "hello",
            typeDelayMillis: 45
        )
        guard case let .params(data) = envelope.body else {
            Issue.record("expected .params body"); return
        }
        let decoded = try JSONDecoder().decode(
            AppCommandParams.TabSendInput.self,
            from: data
        )
        #expect(decoded.typeDelayMillis == 45)
    }

    // MARK: - tab capture (automation-only)

    @Test
    func tabCaptureDefaultsToCurrentTab() {
        let cmd = CLICommands.parse(["deviceterm", "tab", "capture"])
        if case let .tabCapture(ref) = cmd {
            #expect(ref.type == "current")
        } else {
            Issue.record("expected .tabCapture; got \(cmd)")
        }
    }

    @Test
    func tabCaptureWithExplicitRef() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "tab",
            "capture",
            "--tab",
            "abc123"
            ]
            )
        if case let .tabCapture(ref) = cmd {
            #expect(ref.type == "shortId")
            #expect(ref.value == "abc123")
        } else {
            Issue.record("expected .tabCapture; got \(cmd)")
        }
    }

    @Test
    func tabCaptureRejectsUnknownTail() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "tab",
            "capture",
            "garbage-positional"
            ]
            )
        if case .usage = cmd {
            // expected
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    @Test
    func tabCaptureRequestEncodesParams() throws {
        let envelope = try CLICommands.tabCaptureRequest(
            tab: Wire.TabRef(type: "sessionId", value: "S-A")
        )
        #expect(envelope.method == RPCMethod.tabCapture.rawValue)
        guard case let .params(data) = envelope.body else {
            Issue.record("expected .params body"); return
        }
        let decoded = try JSONDecoder().decode(
            AppCommandParams.TabCapture.self,
            from: data
        )
        #expect(decoded.tab.type == "sessionId")
        #expect(decoded.tab.value == "S-A")
    }

    @Test
    func tabBareIsUsage() {
        let cmd = CLICommands.parse(["deviceterm", "tab"])
        if case .usage = cmd {
            // expected
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    // MARK: - Pane subcommands

    @Test
    func paneOpenTerminal() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "pane",
            "open",
            "--terminal"
            ]
            )
        if case let .paneOpenTerminal(tab, cwd, cmdLine) = cmd {
            #expect(tab == nil)
            #expect(cwd == nil)
            #expect(cmdLine == nil)
        } else {
            Issue.record("expected .paneOpenTerminal; got \(cmd)")
        }
    }

    @Test
    func paneOpenTerminalWithTab() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "pane",
            "open",
            "--terminal",
            "--tab",
            "abc123"
            ]
            )
        if case let .paneOpenTerminal(tab, _, _) = cmd {
            #expect(tab?.type == "shortId")
            #expect(tab?.value == "abc123")
        } else {
            Issue.record("expected .paneOpenTerminal; got \(cmd)")
        }
    }

    @Test
    func paneOpenWithoutTerminalIsUsage() {
        let cmd = CLICommands.parse(["deviceterm", "pane", "open"])
        if case .usage = cmd {
            // expected
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    /// `--cwd` and `--cmd` thread to the `OpenPaneTerminal` wire
    /// shape so the new terminal's libghostty surface honors them.
    @Test
    func paneOpenTerminalAcceptsCwdAndCmdFlags() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "pane",
            "open",
            "--terminal",
            "--cwd",
            "/proj",
            "--cmd",
            "claude --print"
            ]
            )
        if case let .paneOpenTerminal(_, cwd, cmdLine) = cmd {
            #expect(cwd == "/proj")
            #expect(cmdLine == "claude --print")
        } else {
            Issue.record("expected .paneOpenTerminal; got \(cmd)")
        }
    }

    @Test
    func paneOpenTerminalRejectsUnknownTail() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "pane",
            "open",
            "--terminal",
            "garbage"
            ]
            )
        if case .usage = cmd {
            // expected
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    @Test
    func paneClose() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "pane",
            "close",
            "--pane",
            "ab12cd"
            ]
            )
        if case let .paneClose(ref, mode) = cmd {
            #expect(ref.type == "shortId")
            #expect(mode == "detach")
        } else {
            Issue.record("expected .paneClose; got \(cmd)")
        }
    }

    @Test
    func paneRenameWithName() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "pane",
            "rename",
            "--pane",
            "ab12cd",
            "iphone-15"
            ]
            )
        if case let .paneRename(_, name) = cmd {
            #expect(name == "iphone-15")
        } else {
            Issue.record("expected .paneRename; got \(cmd)")
        }
    }

    @Test(arguments: ["--help", "-h"])
    func paneRenameHelpFlagIsUsage(trigger: String) {
        let cmd = CLICommands.parse(["deviceterm", "pane", "rename", trigger])
        if case .usage = cmd {
            // expected: same name-position guard as `tab rename`
        } else {
            Issue.record("expected .usage for '\(trigger)'; got \(cmd)")
        }
    }

    @Test
    func paneRenameKeepsBareHelpAsName() {
        let cmd = CLICommands.parse(["deviceterm", "pane", "rename", "help"])
        if case let .paneRename(_, name) = cmd {
            #expect(name == "help")
        } else {
            Issue.record("expected .paneRename; got \(cmd)")
        }
    }

    @Test
    func paneRenameKeepsHelpFlagInsideLongerName() {
        let cmd = CLICommands.parse(
            ["deviceterm", "pane", "rename", "sim", "--help"]
            )
        if case let .paneRename(_, name) = cmd {
            #expect(name == "sim --help")
        } else {
            Issue.record("expected .paneRename; got \(cmd)")
        }
    }

    @Test(arguments: ["--help", "-h"])
    func paneRenameTerminatorForcesHelpFlagAsName(trigger: String) {
        let cmd = CLICommands.parse(
            ["deviceterm", "pane", "rename", "--", trigger]
            )
        if case let .paneRename(_, name) = cmd {
            #expect(name == trigger)
        } else {
            Issue.record("expected .paneRename for '\(trigger)'; got \(cmd)")
        }
    }

    @Test
    func paneInfo() {
        let cmd = CLICommands.parse(["deviceterm", "pane", "info"])
        if case let .paneInfo(ref) = cmd {
            #expect(ref.type == "current")
        } else {
            Issue.record("expected .paneInfo; got \(cmd)")
        }
    }

    @Test
    func paneMoveRequiresToTab() {
        let withFlag = CLICommands.parse(
            [
            "deviceterm",
            "pane",
            "move",
            "--pane",
            "ab12cd",
            "--to-tab",
            "auth"
            ]
            )
        if case let .paneMove(pane, toTab) = withFlag {
            #expect(pane.value == "ab12cd")
            #expect(toTab.value == "auth")
        } else {
            Issue.record("expected .paneMove; got \(withFlag)")
        }

        let missingFlag = CLICommands.parse(
            [
            "deviceterm",
            "pane",
            "move",
            "--pane",
            "ab12cd"
            ]
            )
        if case .usage = missingFlag {
            // expected
        } else {
            Issue.record("expected .usage; got \(missingFlag)")
        }
    }

    @Test
    func deviceAttachParsesRef() {
        let cmd = CLICommands.parse(["deviceterm", "device", "attach", "U-iphone17"])
        if case let .deviceAttach(ref) = cmd {
            #expect(ref == "U-iphone17")
        } else {
            Issue.record("expected .deviceAttach; got \(cmd)")
        }

        // A bare ref-less `device attach` is a usage error.
        if case .usage = CLICommands.parse(["deviceterm", "device", "attach"]) {
            // expected
        } else {
            Issue.record("expected .usage for ref-less device attach")
        }
        // An extra positional past the ref is a usage error too.
        if case .usage = CLICommands.parse(
            ["deviceterm", "device", "attach", "a", "b"]
        ) {
            // expected
        } else {
            Issue.record("expected .usage for device attach with extra positional")
        }
    }

    @Test
    func paneAttachSubverbIsRetired() {
        // `pane attach` was retired in favor of `device attach <ref>`;
        // the parser no longer recognizes it.
        if case .usage = CLICommands.parse(
            ["deviceterm", "pane", "attach", "U-iphone17"]
        ) {
            // expected
        } else {
            Issue.record("expected .usage for retired pane attach")
        }
    }

    // MARK: - device attach resolution (roster + external-sim fallback)

    @Test
    func resolveDeviceAttachUsesRosterSimEntry() {
        let result = CLICommands.resolveDeviceAttach(
            ref: "iPhone 17 Pro",
            roster: Self.attachRoster
        )
        #expect(
            result == .target(
                .sim(udid: "5E6F7A8B-PHONE-0000-0000-000000000000"),
                id: "5E6F7A8B-PHONE-0000-0000-000000000000",
                kind: .sim
            )
        )
    }

    @Test
    func resolveDeviceAttachUsesRosterDeviceEntry() {
        let result = CLICommands.resolveDeviceAttach(
            ref: "fd00:1234::a1b2",
            roster: Self.attachRoster
        )
        #expect(
            result == .target(
                .device(deviceId: "fd00:1234::a1b2"),
                id: "fd00:1234::a1b2",
                kind: .device
            )
        )
    }

    @Test
    func resolveDeviceAttachFallsBackToSimUDIDForUnownedBootedSim() {
        // Regression guard: an externally-booted / orphan sim isn't
        // in the owned-sim roster, so a bare UUID ref must pass through
        // as a sim target (the claim path the retired `pane attach`
        // subverb served), not be rejected.
        let external = "AAAAAAAA-1111-2222-3333-444444444444"
        let result = CLICommands.resolveDeviceAttach(
            ref: external,
            roster: Self.attachRoster
        )
        #expect(result == .target(.sim(udid: external), id: external, kind: .sim))
    }

    @Test
    func resolveDeviceAttachRejectsUnknownNonUUIDRef() {
        // A non-UUID miss is a typo / unknown name: hard not-found, so
        // the CLI surfaces the friendlier roster error.
        #expect(
            CLICommands.resolveDeviceAttach(ref: "typo", roster: Self.attachRoster)
            == .notFound
        )
    }

    @Test
    func resolveDeviceAttachSurfacesAmbiguity() {
        let roster = [
            DeviceRosterEntry(id: "U-1", kind: .sim, name: "twin"),
            DeviceRosterEntry(id: "U-2", kind: .sim, name: "twin")
        ]
        #expect(
            CLICommands.resolveDeviceAttach(ref: "twin", roster: roster)
            == .ambiguous(ids: ["U-1", "U-2"])
        )
    }

    @Test
    func devicesListParses() {
        #expect(CLICommands.parse(["deviceterm", "devices", "list"]) == .devicesList)
        if case .usage = CLICommands.parse(["deviceterm", "devices", "wiggle"]) {
            // expected
        } else {
            Issue.record("expected .usage for unknown devices subcommand")
        }
        // Bare `devices` (no subcommand) is a usage error.
        if case .usage = CLICommands.parse(["deviceterm", "devices"]) {
            // expected
        } else {
            Issue.record("expected .usage for bare devices")
        }
    }

    @Test
    func deviceNounMalformedIsUsage() {
        // Bare `device` and an unknown `device` subcommand both surface
        // the usage hint.
        for argv in [["deviceterm", "device"], ["deviceterm", "device", "wiggle"]] {
            if case .usage = CLICommands.parse(argv) {
                // expected
            } else {
                Issue.record("expected .usage for \(argv)")
            }
        }
    }

    @Test
    func paneUnknownSubcommandIsUsage() {
        let cmd = CLICommands.parse(["deviceterm", "pane", "wiggle"])
        if case .usage = cmd {
            // expected
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    // MARK: - Window subcommands

    @Test
    func windowOpen() {
        #expect(CLICommands.parse(["deviceterm", "window", "open"]) == .windowOpen)
    }

    @Test
    func windowCloseDefaults() {
        let cmd = CLICommands.parse(["deviceterm", "window", "close"])
        if case let .windowClose(ref, mode) = cmd {
            #expect(ref.type == "current")
            #expect(mode == "detach")
        } else {
            Issue.record("expected .windowClose; got \(cmd)")
        }
    }

    @Test
    func windowFocusWithIndex() {
        let cmd = CLICommands.parse(
            [
            "deviceterm",
            "window",
            "focus",
            "--window",
            "2"
            ]
            )
        if case let .windowFocus(ref) = cmd {
            #expect(ref.type == "index")
            #expect(ref.value == "2")
        } else {
            Issue.record("expected .windowFocus; got \(cmd)")
        }
    }

    @Test
    func windowUnknownSubcommandIsUsage() {
        let cmd = CLICommands.parse(["deviceterm", "window", "tilt"])
        if case .usage = cmd {
            // expected
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    // MARK: - Windows verb

    @Test
    func windowsList() {
        #expect(
            CLICommands.parse(["deviceterm", "windows", "list"])
            == .windowsList(all: false)
            )
    }

    @Test
    func windowsListAll() {
        #expect(
            CLICommands.parse(["deviceterm", "windows", "list", "--all"])
            == .windowsList(all: true)
            )
    }

    @Test
    func windowsUnknownSubcommandIsUsage() {
        let cmd = CLICommands.parse(["deviceterm", "windows", "spin"])
        if case .usage = cmd {
            // expected
        } else {
            Issue.record("expected .usage; got \(cmd)")
        }
    }

    // MARK: - Request builders

    @Test
    func tabCloseRequestEncodesWireParams() throws {
        let envelope = try CLICommands.tabCloseRequest(
            tab: Wire.TabRef(type: "current", value: nil),
            mode: "shutdown"
        )
        #expect(envelope.method == RPCMethod.tabClose.rawValue)
        guard case let .params(data) = envelope.body else {
            Issue.record("expected .params body"); return
        }
        let decoded = try JSONDecoder().decode(
            AppCommandParams.CloseTab.self,
            from: data
        )
        #expect(decoded.tab.type == "current")
        #expect(decoded.mode == "shutdown")
    }

    @Test
    func deviceAttachRequestEncodesSimTarget() throws {
        let envelope = try CLICommands.deviceAttachRequest(
            target: .sim(udid: "U-iphone17")
        )
        #expect(envelope.method == RPCMethod.paneAttach.rawValue)
        guard case let .params(data) = envelope.body else {
            Issue.record("expected .params body"); return
        }
        let decoded = try JSONDecoder().decode(
            AppCommandParams.PaneAttach.self,
            from: data
        )
        #expect(decoded.target == .sim(udid: "U-iphone17"))
    }

    @Test
    func deviceAttachRequestEncodesDeviceTarget() throws {
        let envelope = try CLICommands.deviceAttachRequest(
            target: .device(deviceId: "fd00::1")
        )
        #expect(envelope.method == RPCMethod.paneAttach.rawValue)
        guard case let .params(data) = envelope.body else {
            Issue.record("expected .params body"); return
        }
        let decoded = try JSONDecoder().decode(
            AppCommandParams.PaneAttach.self,
            from: data
        )
        #expect(decoded.target == .device(deviceId: "fd00::1"))
    }

    @Test
    func devicesListRequestHasNoBody() {
        let envelope = CLICommands.devicesListRequest()
        #expect(envelope.method == RPCMethod.devicesList.rawValue)
        // Session comes from the connection's authenticated context,
        // so the request carries no params body.
        guard case .empty = envelope.body else {
            Issue.record("expected .empty body; got \(envelope.body)")
            return
        }
    }

    @Test
    func windowsListRequestCarriesAllFlag() throws {
        let envelope = try CLICommands.windowsListRequest(all: true)
        #expect(envelope.method == RPCMethod.windowsList.rawValue)
        guard case let .params(data) = envelope.body else {
            Issue.record("expected .params body"); return
        }
        let decoded = try JSONDecoder().decode(
            AppCommandParams.WindowsList.self,
            from: data
        )
        #expect(decoded.all)
    }

    // MARK: - CWD normalization

    /// `--cwd` is resolved against the CLI process's CWD before
    /// the wire encoding so libghostty's `working_directory` (which
    /// requires absolute paths) doesn't silently ignore relative
    /// or `~`-prefixed paths. `nil` and empty pass through unchanged.
    @Test
    func normalizeCwdLeavesAbsolutePathsAlone() {
        #expect(CLICommands.normalizeCwd("/tmp") == "/tmp")
        #expect(CLICommands.normalizeCwd("/usr/local/bin") == "/usr/local/bin")
    }

    @Test
    func normalizeCwdResolvesTilde() {
        let home = NSHomeDirectory()
        #expect(CLICommands.normalizeCwd("~") == home)
        #expect(CLICommands.normalizeCwd("~/proj") == "\(home)/proj")
    }

    @Test
    func normalizeCwdResolvesRelativeAgainstCWD() {
        let cwd = FileManager.default.currentDirectoryPath
        #expect(CLICommands.normalizeCwd(".") == cwd)
        #expect(CLICommands.normalizeCwd("subdir") == "\(cwd)/subdir")
    }

    @Test
    func normalizeCwdCollapsesDoubleDots() {
        // `/tmp/foo/..` standardizes to `/tmp`, and the same logic catches
        // `./../foo` against the CLI's CWD too. Test the absolute
        // case since the CWD-relative one depends on the test
        // runner's location.
        #expect(CLICommands.normalizeCwd("/tmp/foo/..") == "/tmp")
    }

    @Test
    func normalizeCwdPassesNilAndEmptyThrough() {
        #expect(CLICommands.normalizeCwd(nil) == nil)
        #expect(CLICommands.normalizeCwd("")?.isEmpty == true)
    }

    // MARK: - Echo labels

    @Test
    func echoLabels() {
        #expect(
            CLICommands.echoLabel(
            Wire.TabRef(type: "current", value: nil)
        ) == "current"
            )
        #expect(
            CLICommands.echoLabel(
            Wire.TabRef(type: "sessionId", value: "S-A")
        ) == "S-A"
            )
        #expect(
            CLICommands.echoLabel(
            Wire.PaneRef(type: "shortId", value: "ab12")
        ) == "ab12"
            )
        #expect(
            CLICommands.echoLabel(
            Wire.WindowRef(type: "index", value: "2")
        ) == "2"
            )
    }
}
