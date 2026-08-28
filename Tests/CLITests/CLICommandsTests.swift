// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// CLI argv parsing: pure-logic dispatch. `deviceterm-cli` is invoked
// from the shell, so the argv → command mapping is the load-bearing
// contract: a regression here strands every tab's `deviceterm` call.

@Test
func parseEmptyArgvIsUsage() {
    #expect(CLICommands.parse(["deviceterm"]) == .usage(message: nil))
}

@Test
func parseUnknownTopLevelIsUsage() {
    #expect(CLICommands.parse(["deviceterm", "wat"]) == .usage(message: nil))
}

@Test
func parseTabsListResolvesToTabsList() {
    #expect(CLICommands.parse(["deviceterm", "tabs", "list"]) == .tabsList)
}

@Test
func parseTabsBareIsUsageWithSpecificMessage() throws {
    // `tabs` without a subcommand is a user typo; the more specific
    // stderr message helps them fix it without scanning the full
    // usage block.
    let result = CLICommands.parse(["deviceterm", "tabs"])
    guard case let .usage(message) = result else {
        Issue.record("expected .usage, got \(result)")
        return
    }
    let text = try #require(message)
    #expect(text.contains("tabs"))
    #expect(text.contains("list"))
}

@Test
func parseTabsUnknownSubcommandIsUsageWithSpecificMessage() throws {
    let result = CLICommands.parse(["deviceterm", "tabs", "burn"])
    guard case let .usage(message) = result else {
        Issue.record("expected .usage, got \(result)")
        return
    }
    let text = try #require(message)
    #expect(text.contains("tabs"))
}

// MARK: - Wire shape

@Test
func tabsListRequestShape() {
    // Pin the wire shape: method name and body. The id is `1`
    // because the CLI is one-shot: the daemon doesn't care about
    // uniqueness across CLI invocations (each invocation gets its
    // own connection).
    let envelope = CLICommands.tabsListRequest()
    #expect(envelope.id == 1)
    #expect(envelope.type == .request)
    #expect(envelope.method == "tabs.list")
    if case .empty = envelope.body {
        // OK
    } else {
        Issue.record("expected .empty body, got \(envelope.body)")
    }
}

@Test
func tabsListRequestEncodesToValidFrame() throws {
    // End-to-end wire check: the envelope must round-trip through
    // RPCFraming + RPCEnvelope back into something the daemon's
    // dispatcher would recognize.
    let envelope = CLICommands.tabsListRequest()
    let frame = RPCFraming.encode(try envelope.encode())
    let (payload, consumed) = try #require(try RPCFraming.decodeNext(from: frame))
    #expect(consumed == frame.count)
    let decoded = try RPCEnvelope.decode(payload)
    #expect(decoded.method == "tabs.list")
    #expect(decoded.type == .request)
}

// MARK: - Input grammar (positional operands, flag modifiers, --pane)

@Test
func parsePanesListResolvesToPanesList() {
    #expect(CLICommands.parse(["deviceterm", "panes", "list"]) == .panesList)
}

@Test
func parseTapResolvesToTap() {
    #expect(
        CLICommands.parse(["deviceterm", "tap", "0.5", "0.25"])
        == .tap(pane: nil, x: 0.5, y: 0.25)
        )
}

@Test
func parseTapWithPaneSelector() {
    // `--pane <ref>` is the universal targeting selector; it accepts
    // any ref shape (here a shortId).
    #expect(
        CLICommands.parse(["deviceterm", "tap", "0.1", "0.2", "--pane", "phn002"])
        == .tap(pane: "phn002", x: 0.1, y: 0.2)
        )
}

@Test
func parseButtonResolvesToButton() {
    #expect(
        CLICommands.parse(["deviceterm", "button", "digitalCrown"])
        == .button(pane: nil, button: .digitalCrown)
        )
}

@Test
func parseCrownResolvesToCrown() {
    #expect(
        CLICommands.parse(["deviceterm", "crown", "30"])
        == .crown(pane: nil, delta: 30, velocity: nil, durationMs: nil)
        )
}

@Test
func parseCrownNegativeDeltaAndFlags() {
    // A leading-`-` delta is a positional, not a flag; velocity/duration
    // /pane ride as flags in any order.
    #expect(
        CLICommands.parse(
        ["deviceterm", "crown", "-15", "--velocity", "2", "--duration", "200", "--pane", "W"]
    )
        == .crown(pane: "W", delta: -15, velocity: 2, durationMs: 200)
        )
}

@Test
func parseCrownWithPaneSelector() {
    // The crown branch carries velocity/duration; confirm `--pane`
    // lands in the targeting slot.
    #expect(
        CLICommands.parse(["deviceterm", "crown", "30", "--pane", "wch001"])
        == .crown(pane: "wch001", delta: 30, velocity: nil, durationMs: nil)
        )
}

@Test
func parseCrownBadDeltaIsUsage() {
    guard case .usage = CLICommands.parse(["deviceterm", "crown", "abc"]) else {
        Issue.record("expected .usage for non-numeric delta")
        return
    }
}

@Test
func parseCrownMissingDeltaIsUsage() {
    guard case .usage = CLICommands.parse(["deviceterm", "crown"]) else {
        Issue.record("expected .usage for missing delta")
        return
    }
}

@Test
func parseTextResolvesToText() {
    #expect(
        CLICommands.parse(["deviceterm", "text", "hello world"])
        == .text(pane: nil, text: "hello world")
        )
}

@Test
func parseTextPreservesUnknownDashDashTokens() {
    // `text` types arbitrary input, so unrecognized `--` tokens are literal,
    // not flags: the splitter must not consume them.
    #expect(
        CLICommands.parse(["deviceterm", "text", "hello", "--world"])
        == .text(pane: nil, text: "hello --world")
        )
    #expect(
        CLICommands.parse(["deviceterm", "text", "--help"])
        == .text(pane: nil, text: "--help")
        )
}

@Test
func parseTextDashDashTerminatorIsLiteral() {
    // A bare `--` forces everything after it literal, even names that
    // would otherwise be recognized flags.
    #expect(
        CLICommands.parse(["deviceterm", "text", "--", "--pane", "X"])
        == .text(pane: nil, text: "--pane X")
        )
}

@Test
func parseTextStillHonorsPaneFlag() {
    #expect(
        CLICommands.parse(["deviceterm", "text", "hello", "--pane", "W"])
        == .text(pane: "W", text: "hello")
        )
}

@Test
func parseTextTreatsNonTextValuedFlagsAsLiteral() {
    // `--duration` / `--velocity` aren't `text` modifiers, so they (and
    // their would-be values) must be typed literally: flag parsing is
    // scoped to the active command.
    #expect(
        CLICommands.parse(["deviceterm", "text", "--duration", "100"])
        == .text(pane: nil, text: "--duration 100")
        )
    #expect(
        CLICommands.parse(["deviceterm", "text", "hello", "--velocity", "fast"])
        == .text(pane: nil, text: "hello --velocity fast")
        )
}

@Test
func parseKeyResolvesToKey() {
    #expect(
        CLICommands.parse(["deviceterm", "key", "0", "down"])
        == .key(pane: nil, keyCode: 0, down: true)
        )
}

@Test
func parseKeyAcceptsHexPrefix() {
    // Apple's HIToolbox `kVK_*` constants are documented in hex;
    // the canonical Tab key is `kVK_Tab = 0x30`. The parser accepts
    // both forms so an agent typing the documented hex literal
    // doesn't fall into `.usage`. The `0X` upper-case form works
    // too, since the prefix detection is case-insensitive.
    #expect(
        CLICommands.parse(["deviceterm", "key", "0x30", "down"])
        == .key(pane: nil, keyCode: 0x30, down: true)
        )
    #expect(
        CLICommands.parse(["deviceterm", "key", "0XFF", "up"])
        == .key(pane: nil, keyCode: 0xFF, down: false)
        )
}

@Test
func parseKeyRejectsMalformedHex() {
    // `0xzz` looks like hex but isn't, so bail with `.usage` rather
    // than silently sending a 0 keyCode.
    guard case .usage = CLICommands.parse(["deviceterm", "key", "0xzz", "down"]) else {
        Issue.record("malformed hex should yield .usage")
        return
    }
}

@Test
func parseAxPointResolvesToAxPoint() {
    #expect(
        CLICommands.parse(["deviceterm", "ax", "point", "0.5", "0.5"])
        == .axPoint(pane: nil, x: 0.5, y: 0.5)
        )
}

// MARK: - Coverage backfill for verbs that lacked happy-path parse tests
//
// The dispatch sites for these commands flow through
// `sendResolved(ref:fields:build:)` for the echo receipt; the
// tests below pin the parser → command mapping so a typo at any
// dispatch site is caught at compile/test time, not by silent
// runtime drift.

@Test
func parseSwipeHappyPath() {
    #expect(
        CLICommands.parse(
        ["deviceterm", "swipe", "0.5", "0.8", "0.5", "0.2"]
    )
        == .swipe(
            pane: nil,
            fromX: 0.5,
            fromY: 0.8,
            toX: 0.5,
            toY: 0.2,
            durationMs: nil,
            holdMs: nil
            )
        )
}

@Test
func parseSwipeWithDurationAndUdid() {
    #expect(
        CLICommands.parse(
        [
            "deviceterm",
            "swipe",
            "0",
            "0",
            "1",
            "1",
            "--duration",
            "250",
            "--pane",
            "W"
        ]
    )
        == .swipe(
            pane: "W",
            fromX: 0,
            fromY: 0,
            toX: 1,
            toY: 1,
            durationMs: 250,
            holdMs: nil
            )
        )
}

@Test
func parseSwipeWithPaneSelector() {
    // The swipe branch has its own valued-flag set; confirm it
    // recognizes `--pane` alongside `--duration`.
    #expect(
        CLICommands.parse(
        ["deviceterm", "swipe", "0", "0", "1", "1", "--pane", "wch001"]
    )
        == .swipe(
            pane: "wch001",
            fromX: 0,
            fromY: 0,
            toX: 1,
            toY: 1,
            durationMs: nil,
            holdMs: nil
            )
        )
}

@Test
func parseSwipeMalformedCoordsIsUsage() {
    // Wrong arity (3 instead of 4) and non-numeric both surface as
    // .usage so the user sees the per-verb hint rather than a
    // silent default.
    guard case .usage = CLICommands.parse(
        ["deviceterm", "swipe", "0", "1", "2"]
    ) else {
        Issue.record("3-arg swipe should be .usage")
        return
    }
    guard case .usage = CLICommands.parse(
        ["deviceterm", "swipe", "a", "b", "c", "d"]
    ) else {
        Issue.record("non-numeric swipe should be .usage")
        return
    }
}

@Test
func parseSwipeWithHold() {
    #expect(
        CLICommands.parse(
        ["deviceterm", "swipe", "0.5", "1", "0.5", "0.45", "--duration", "300", "--hold", "700"]
    )
        == .swipe(
            pane: nil,
            fromX: 0.5,
            fromY: 1,
            toX: 0.5,
            toY: 0.45,
            durationMs: 300,
            holdMs: 700
            )
        )
}

@Test
func parseSwipeMalformedHoldIsUsage() {
    guard case .usage = CLICommands.parse(
        ["deviceterm", "swipe", "0", "0", "1", "1", "--hold", "soon"]
    ) else {
        Issue.record("non-integer --hold should be .usage")
        return
    }
}

@Test
func parseAppSwitcherHappyPath() {
    #expect(CLICommands.parse(["deviceterm", "app-switcher"]) == .appSwitcher(pane: nil))
    #expect(
        CLICommands.parse(["deviceterm", "app-switcher", "--pane", "wch001"])
        == .appSwitcher(pane: "wch001")
    )
}

@Test
func parseAppSwitcherWithStrayPositionalIsUsage() {
    guard case .usage = CLICommands.parse(["deviceterm", "app-switcher", "0.5"]) else {
        Issue.record("app-switcher takes no positional args; stray arg should be .usage")
        return
    }
}

@Test
func parseLongPressHappyPath() {
    #expect(
        CLICommands.parse(
        ["deviceterm", "long-press", "0.5", "0.5"]
    )
        == .longPress(pane: nil, x: 0.5, y: 0.5, durationMs: nil)
        )
}

@Test
func parseLongPressWithDuration() {
    #expect(
        CLICommands.parse(
        ["deviceterm", "long-press", "0.4", "0.6", "--duration", "800"]
    )
        == .longPress(pane: nil, x: 0.4, y: 0.6, durationMs: 800)
        )
}

@Test
func parsePinchHappyPath() {
    let argv = [
        "deviceterm",
        "pinch",
        "0.45",
        "0.5",
        "0.55",
        "0.5",
        "0.30",
        "0.5",
        "0.70",
        "0.5"
    ]
    #expect(
        CLICommands.parse(argv)
        == .pinch(
            pane: nil,
            fromF1X: 0.45,
            fromF1Y: 0.5,
            fromF2X: 0.55,
            fromF2Y: 0.5,
            toF1X: 0.30,
            toF1Y: 0.5,
            toF2X: 0.70,
            toF2Y: 0.5,
            durationMs: nil
            )
        )
}

@Test
func parsePinchWrongArityIsUsage() {
    // Seven coords (one short of the required eight) is a common
    // off-by-one mistake; must surface as .usage.
    guard case .usage = CLICommands.parse(
        [
            "deviceterm",
            "pinch",
            "0.5",
            "0.5",
            "0.5",
            "0.5",
            "0.5",
            "0.5",
            "0.5"
        ]
    ) else {
        Issue.record("7-coord pinch should be .usage")
        return
    }
}

@Test
func parseRotateHappyPath() {
    #expect(
        CLICommands.parse(["deviceterm", "rotate", "landscapeLeft"])
        == .rotate(pane: nil, target: .absolute(.landscapeLeft))
        )
    #expect(
        CLICommands.parse(["deviceterm", "rotate", "portrait"])
        == .rotate(pane: nil, target: .absolute(.portrait))
        )
}

/// `rotate` takes a direction on the same positional as an orientation.
/// The two vocabularies don't overlap, so neither shadows the other.
@Test(
    "rotate accepts a relative direction",
    arguments: [
        ("left", RotationDirection.left),
        ("right", .right),
        ("LEFT", .left),
        ("Right", .right)
    ]
)
func parseRotateAcceptsADirection(_ spelling: String, expected: RotationDirection) {
    #expect(
        CLICommands.parse(["deviceterm", "rotate", spelling])
        == .rotate(pane: nil, target: .relative(expected))
    )
}

@Test
func parseRotateUnknownOrientationIsUsage() {
    guard case .usage = CLICommands.parse(
        ["deviceterm", "rotate", "sideways"]
    ) else {
        Issue.record("unknown orientation should be .usage")
        return
    }
}

@Test
func parseRotateUsageListsBothVocabularies() throws {
    guard case let .usage(message) = CLICommands.parse(
        ["deviceterm", "rotate", "widdershins"]
    ) else {
        Issue.record("unknown rotate argument should be .usage")
        return
    }
    let text = try #require(message)
    #expect(text.contains("portrait"))
    #expect(text.contains("|left|right>"))
}

/// `rotate` accepts kebab-case (canonical), snake_case, all-lowercase,
/// and mixed-case as synonyms of the wire enum's camelCase form.
@Test(
    "rotate orientation spellings normalize",
    arguments: [
        "landscape-right",
        "landscape_right",
        "landscaperight",
        "LandscapeRight",
        "landscapeRight"  // canonical wire form still works
    ]
)
func parseRotateAcceptsAlternateSpellings(_ spelling: String) {
    #expect(
        CLICommands.parse(["deviceterm", "rotate", spelling])
        == .rotate(pane: nil, target: .absolute(.landscapeRight))
    )
}

/// `button` mirrors the same parse normalization for its multi-word
/// HardwareButton cases.
@Test(
    "button HW name spellings normalize",
    arguments: [
        ("apple-pay", HardwareButton.applePay),
        ("apple_pay", .applePay),
        ("applepay", .applePay),
        ("digital-crown", .digitalCrown),
        ("digital_crown", .digitalCrown),
        ("DigitalCrown", .digitalCrown)
    ]
)
func parseButtonAcceptsAlternateSpellings(
    spelling: String,
    expected: HardwareButton
) {
    #expect(
        CLICommands.parse(["deviceterm", "button", spelling])
        == .button(pane: nil, button: expected)
    )
}

@Test
func parseAxTreeResolvesToAxTree() {
    #expect(
        CLICommands.parse(["deviceterm", "ax", "tree"])
        == .axTree(pane: nil)
        )
    #expect(
        CLICommands.parse(["deviceterm", "ax", "tree", "--pane", "U"])
        == .axTree(pane: "U")
        )
}

@Test
func parseAxPointAcceptsPane() {
    #expect(
        CLICommands.parse(
        ["deviceterm", "ax", "point", "0.5", "0.5", "--pane", "U"]
    )
        == .axPoint(pane: "U", x: 0.5, y: 0.5)
        )
}

@Test
func parseAxRejectsUnknownSubcommand() {
    guard case .usage = CLICommands.parse(["deviceterm", "ax", "burn"]) else {
        Issue.record("unknown ax subcommand should be .usage")
        return
    }
}

@Test
func parseKeyMissingDirectionIsUsage() {
    // Missing direction (just `key 0x30`) and wrong direction
    // (`key 0 sideways`) both bail.
    guard case .usage = CLICommands.parse(["deviceterm", "key", "0x30"]) else {
        Issue.record("missing direction should be .usage")
        return
    }
    guard case .usage = CLICommands.parse(
        ["deviceterm", "key", "0", "sideways"]
    ) else {
        Issue.record("unknown direction should be .usage")
        return
    }
}

@Test
func parseButtonUnknownIsUsage() {
    guard case .usage = CLICommands.parse(
        ["deviceterm", "button", "ringer"]
    ) else {
        Issue.record("unknown button should be .usage")
        return
    }
}

@Test
func parseTapMissingArgsIsUsage() {
    guard case .usage = CLICommands.parse(["deviceterm", "tap"]) else {
        Issue.record("bare tap should be .usage")
        return
    }
    guard case .usage = CLICommands.parse(["deviceterm", "tap", "0.5"]) else {
        Issue.record("one-arg tap should be .usage")
        return
    }
}

@Test
func parseTapNonNumericIsUsage() {
    guard case .usage = CLICommands.parse(["deviceterm", "tap", "left", "top"]) else {
        Issue.record("non-numeric tap should be .usage")
        return
    }
}

@Test
func parseTextMissingArgIsUsage() {
    guard case .usage = CLICommands.parse(["deviceterm", "text"]) else {
        Issue.record("bare text should be .usage")
        return
    }
}

@Test
func parseLongPressMissingCoordsIsUsage() {
    guard case .usage = CLICommands.parse(["deviceterm", "long-press"]) else {
        Issue.record("bare long-press should be .usage")
        return
    }
    guard case .usage = CLICommands.parse(["deviceterm", "long-press", "a", "b"]) else {
        Issue.record("non-numeric long-press should be .usage")
        return
    }
}

@Test
func parseButtonMissingArgIsUsage() {
    guard case .usage = CLICommands.parse(["deviceterm", "button"]) else {
        Issue.record("bare button should be .usage")
        return
    }
}

@Test
func parseRotateMissingArgIsUsage() {
    guard case .usage = CLICommands.parse(["deviceterm", "rotate"]) else {
        Issue.record("bare rotate should be .usage")
        return
    }
}

@Test
func parseAxPointMissingCoordsIsUsage() {
    guard case .usage = CLICommands.parse(
        ["deviceterm", "ax", "point"]
    ) else {
        Issue.record("bare ax point should be .usage")
        return
    }
    guard case .usage = CLICommands.parse(
        ["deviceterm", "ax", "point", "0.5"]
    ) else {
        Issue.record("one-arg ax point should be .usage")
        return
    }
}

@Test
func parseAxBareIsUsage() {
    // `deviceterm ax` with no subcommand: the parser falls through
    // to the dispatch's default usage block.
    guard case .usage = CLICommands.parse(["deviceterm", "ax"]) else {
        Issue.record("bare ax should be .usage")
        return
    }
}

@Test
func parseSwipeMissingDurationValueIsUsage() {
    // A flag without its value: the splitter returns nil and the
    // parser surfaces the "a flag is missing its value" hint.
    guard case .usage = CLICommands.parse(
        ["deviceterm", "swipe", "0", "0", "1", "1", "--duration"]
    ) else {
        Issue.record("bare --duration should be .usage")
        return
    }
}

// MARK: - Input wire shapes

@Test
func crownRequestShape() throws {
    let envelope = try CLICommands.crownRequest(
        paneId: "PID",
        delta: 12.5,
        velocity: nil,
        durationMs: nil
    )
    #expect(envelope.id == 1)
    #expect(envelope.type == .request)
    #expect(envelope.method == "pane.input.crown")
    guard case let .params(data) = envelope.body else {
        Issue.record("expected .params body, got \(envelope.body)")
        return
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["paneId"] as? String == "PID")
    #expect(object?["delta"] as? Double == 12.5)
    // nil optionals must be omitted so the daemon applies its defaults.
    #expect(object?["velocity"] == nil)
    #expect(object?["durationMs"] == nil)
}

@Test
func buttonRequestShape() throws {
    let envelope = try CLICommands.buttonRequest(paneId: "PID", button: .digitalCrown)
    #expect(envelope.method == "pane.input.button")
    guard case let .params(data) = envelope.body else {
        Issue.record("expected .params body, got \(envelope.body)")
        return
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["button"] as? String == "digitalCrown")
}

@Test
func panesListRequestShape() throws {
    let envelope = try CLICommands.panesListRequest(sessionId: "SID", cap: "CAP")
    #expect(envelope.method == "panes.list")
    guard case let .params(data) = envelope.body else {
        Issue.record("expected .params body, got \(envelope.body)")
        return
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["sessionId"] as? String == "SID")
    #expect(object?["cap"] as? String == "CAP")
}

// MARK: - ax sweep

@Test
func parseAxSweepReturnsAxSweepWithNoStep() {
    if case let .axSweep(udid, step, budgetMs) = CLICommands.parse(["deviceterm", "ax", "sweep"]) {
        #expect(udid == nil)
        #expect(step == nil)
        #expect(budgetMs == nil)
    } else {
        Issue.record("expected .axSweep")
    }
}

@Test
func parseAxSweepAcceptsStepFlag() {
    if case let .axSweep(udid, step, budgetMs) = CLICommands.parse(
        ["deviceterm", "ax", "sweep", "--step", "0.1"]
    ) {
        #expect(udid == nil)
        #expect(step == 0.1)
        #expect(budgetMs == nil)
    } else {
        Issue.record("expected .axSweep with step 0.1")
    }
}

@Test
func parseAxSweepRejectsNonNumericStep() {
    let result = CLICommands.parse(["deviceterm", "ax", "sweep", "--step", "abc"])
    guard case let .usage(message) = result else {
        Issue.record("expected .usage, got \(result)")
        return
    }
    #expect(message?.contains("--step") == true)
}

@Test
func parseAxSweepAcceptsBudgetFlag() {
    if case let .axSweep(udid, step, budgetMs) = CLICommands.parse(
        ["deviceterm", "ax", "sweep", "--step", "0.02", "--budget", "20000"]
    ) {
        #expect(udid == nil)
        #expect(step == 0.02)
        // Carried verbatim. Clamping is the daemon's alone; the CLI neither
        // bounds this value nor sizes anything from it.
        #expect(budgetMs == 20_000)
    } else {
        Issue.record("expected .axSweep with budget 20000")
    }
}

@Test
func parseAxSweepRejectsNonIntegerBudget() {
    // Milliseconds, like `--duration`, so a fractional second reads as a
    // usage error rather than truncating to a budget the caller didn't ask
    // for.
    for raw in ["abc", "1.5"] {
        let result = CLICommands.parse(["deviceterm", "ax", "sweep", "--budget", raw])
        guard case let .usage(message) = result else {
            Issue.record("expected .usage for --budget \(raw), got \(result)")
            continue
        }
        #expect(message?.contains("--budget") == true)
    }
}

@Test
func parseAxSweepAcceptsPane() {
    if case let .axSweep(pane, step, _) = CLICommands.parse(
        ["deviceterm", "ax", "sweep", "--pane", "ABCD-1234"]
    ) {
        #expect(pane == "ABCD-1234")
        #expect(step == nil)
    } else {
        Issue.record("expected .axSweep with pane")
    }
}

@Test
func parseAxSweepAcceptsPaneSelector() {
    // The ax branch has its own valued-flag set (`pane`, `step`,
    // `budget`); confirm `--pane` resolves the target.
    if case let .axSweep(pane, step, _) = CLICommands.parse(
        ["deviceterm", "ax", "sweep", "--pane", "phn002"]
    ) {
        #expect(pane == "phn002")
        #expect(step == nil)
    } else {
        Issue.record("expected .axSweep with pane")
    }
}

@Test
func axSweepRequestShape() throws {
    let envelope = try CLICommands.axSweepRequest(paneId: "PID", step: 0.1, budgetMs: 20_000)
    #expect(envelope.method == "pane.ax.sweep")
    guard case let .params(data) = envelope.body else {
        Issue.record("expected .params body, got \(envelope.body)")
        return
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["paneId"] as? String == "PID")
    #expect(object?["step"] as? Double == 0.1)
    #expect(object?["budgetMs"] as? Int == 20_000)
}

@Test
func axSweepRequestOmitsNilStepAndBudget() throws {
    let envelope = try CLICommands.axSweepRequest(paneId: "PID", step: nil, budgetMs: nil)
    guard case let .params(data) = envelope.body else {
        Issue.record("expected .params body, got \(envelope.body)")
        return
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["paneId"] as? String == "PID")
    // Both must be omitted so the daemon applies its own defaults, and so a
    // daemon predating `budgetMs` sees the request it always saw.
    #expect(object?["step"] == nil)
    #expect(object?["budgetMs"] == nil)
}
