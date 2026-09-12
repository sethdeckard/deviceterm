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
    // The refusal names the verb it did not recognize.
    guard case let .usage(message) = CLICommands.parse(["deviceterm", "wat"]) else {
        Issue.record("expected .usage for an unknown verb")
        return
    }
    #expect(message?.contains("wat") ?? false)
}

@Test
func parseTabListResolvesToTabList() {
    #expect(CLICommands.parse(["deviceterm", "tab", "list"]) == .tabList(window: nil, all: false))
}

@Test
func parseTabBareIsUsageWithSpecificMessage() throws {
    // `tab` without a subcommand is a user typo; the more specific
    // stderr message helps them fix it without scanning the full
    // usage block.
    let result = CLICommands.parse(["deviceterm", "tab"])
    guard case let .usage(message) = result else {
        Issue.record("expected .usage, got \(result)")
        return
    }
    let text = try #require(message)
    #expect(text.contains("tab"))
    #expect(text.contains("list"))
}

@Test
func parseTabUnknownSubcommandIsUsageWithSpecificMessage() throws {
    let result = CLICommands.parse(["deviceterm", "tab", "burn"])
    guard case let .usage(message) = result else {
        Issue.record("expected .usage, got \(result)")
        return
    }
    let text = try #require(message)
    #expect(text.contains("tab"))
}

// MARK: - Wire shape

@Test
func tabListRequestShape() throws {
    // Pin the wire shape: method name and body. The id is `1`
    // because the CLI is one-shot: the daemon doesn't care about
    // uniqueness across CLI invocations (each invocation gets its
    // own connection).
    let envelope = try CLICommands.tabListRequest(window: nil, all: false)
    #expect(envelope.id == 1)
    #expect(envelope.type == .request)
    #expect(envelope.method == "tab.list")
    guard case let .params(data) = envelope.body else {
        Issue.record("expected params body, got \(envelope.body)")
        return
    }
    #expect(
        try JSONDecoder().decode(AppCommandParams.ListTabs.self, from: data)
            == .init(window: nil, all: false)
    )
}

@Test
func tabListRequestEncodesToValidFrame() throws {
    // End-to-end wire check: the envelope must round-trip through
    // RPCFraming + RPCEnvelope back into something the daemon's
    // dispatcher would recognize.
    let envelope = try CLICommands.tabListRequest(window: nil, all: false)
    let frame = RPCFraming.encode(try envelope.encode())
    let (payload, consumed) = try #require(try RPCFraming.decodeNext(from: frame))
    #expect(consumed == frame.count)
    let decoded = try RPCEnvelope.decode(payload)
    #expect(decoded.method == "tab.list")
    #expect(decoded.type == .request)
}

// MARK: - Input grammar (positional operands, flag modifiers, --pane)

@Test
func parsePaneListResolvesToPaneList() {
    #expect(CLICommands.parse(["deviceterm", "pane", "list"]) == .paneList(tab: nil))
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
func parseCrownAcceptsASignedVelocity() {
    // A signed value has to reach the velocity option as well as the
    // delta operand.
    #expect(
        CLICommands.parse(["deviceterm", "crown", "30", "--velocity", "-2"])
        == .crown(pane: nil, delta: 30, velocity: -2, durationMs: nil)
        )
    #expect(
        CLICommands.parse(["deviceterm", "crown", "-30", "--velocity", "-2"])
        == .crown(pane: nil, delta: -30, velocity: -2, durationMs: nil)
        )
}

@Test
func parseCrownAcceptsAnExplicitTerminator() {
    // A caller who escaped the operand themselves is left alone.
    #expect(
        CLICommands.parse(["deviceterm", "crown", "--", "-30"])
        == .crown(pane: nil, delta: -30, velocity: nil, durationMs: nil)
        )
}

@Test
func parseCrownTakesASignedDeltaInAnyFlagOrder() {
    // The normalizer moves the operand and leaves the flags where they
    // are, so a signed delta reads the same before, between, and after
    // them.
    let expected = CLICommand.crown(pane: "W", delta: -15, velocity: 2, durationMs: 200)
    let orderings = [
        ["crown", "-15", "--velocity", "2", "--duration", "200", "--pane", "W"],
        ["crown", "--velocity", "2", "-15", "--duration", "200", "--pane", "W"],
        ["crown", "--velocity", "2", "--duration", "200", "--pane", "W", "-15"]
    ]
    for argv in orderings {
        #expect(CLICommands.parse(["deviceterm"] + argv) == expected, "\(argv)")
    }
    // A signed value ahead of the signed operand: the delta has to
    // survive a negative velocity sitting directly before it.
    #expect(
        CLICommands.parse(["deviceterm", "crown", "--velocity", "-2", "-30"])
        == .crown(pane: nil, delta: -30, velocity: -2, durationMs: nil)
        )
}

@Test
func parseCrownReportsAnUnknownOptionRatherThanTheOperand() {
    // An unrecognized flag doesn't take a value, so the signed token
    // after it is still the operand and the refusal names the flag.
    guard case let .usage(message) = CLICommands.parse(
        ["deviceterm", "crown", "--nope", "-30"]
    ) else {
        Issue.record("expected .usage for an unknown option")
        return
    }
    #expect(message?.contains("--nope") ?? false, "refusal should name --nope: \(message ?? "")")
}

@Test
func parseCrownLeavesOtherVerbsAlone() {
    // The rewrite is crown's own. A dashed token on any other verb is
    // still refused rather than quietly re-homed.
    guard case .usage = CLICommands.parse(["deviceterm", "tap", "-15", "0.5"]) else {
        Issue.record("expected .usage; the rewrite must not reach `tap`")
        return
    }
}

@Test
func parseCrownKeepsFractionalAndPositiveDeltas() {
    #expect(
        CLICommands.parse(["deviceterm", "crown", "-0.5"])
        == .crown(pane: nil, delta: -0.5, velocity: nil, durationMs: nil)
        )
    #expect(
        CLICommands.parse(["deviceterm", "crown", "0.5"])
        == .crown(pane: nil, delta: 0.5, velocity: nil, durationMs: nil)
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

@Test("a deadline that cannot elapse is refused", arguments: [
    ["tap", "--label", "Save", "--timeout", "0"],
    ["tap", "--label", "Save", "--timeout", "-5"],
    ["wait", "ax", "--label", "Save", "--timeout", "0"],
    ["wait", "pane", "rendering", "--timeout", "0"],
    ["wait", "orientation", "portrait", "--timeout", "0"],
    ["wait", "surface", "quiescent", "--timeout", "0"]
])
func parseRejectsANonPositiveTimeout(argv: [String]) {
    // Every verb that takes `--timeout` refuses a deadline that has
    // already passed. A selector tap with a zero deadline would report
    // a timeout without having looked.
    guard case let .usage(message) = CLICommands.parse(["deviceterm"] + argv) else {
        Issue.record("expected .usage for \(argv)")
        return
    }
    #expect(message?.contains("--timeout") ?? false)
}

@Test
func parseTapKeepsAPositiveTimeout() {
    let parsed = CLICommands.parse(
        ["deviceterm", "tap", "--label", "Save", "--timeout", "1500"]
        )
    guard case let .tapElement(_, _, timeoutMs) = parsed else {
        Issue.record("expected .tapElement; got \(parsed)")
        return
    }
    #expect(timeoutMs == 1_500)
}

@Test
func parseTextResolvesToText() {
    #expect(
        CLICommands.parse(["deviceterm", "text", "hello world"])
        == .text(pane: nil, text: "hello world")
        )
}

@Test
func parseTextRejectsUnknownDashDashTokens() {
    // A dashed word in the payload is read as a flag and refused, so
    // typing one takes the `--` terminator. The refusal is the point: it
    // keeps a mistyped flag from being sent to the device.
    guard case .usage = CLICommands.parse(["deviceterm", "text", "hello", "--world"]) else {
        Issue.record("expected .usage for an unknown dashed payload word")
        return
    }
}

@Test
func parseTextHelpFlagAsksForHelp() {
    // `--help` reaches the help page rather than being typed, on `text`
    // as on every other verb. `--` is how the literal string is typed;
    // `parseTextDashDashTerminatorIsLiteral` covers that.
    #expect(
        CLICommands.parse(["deviceterm", "text", "--help"])
        == .help(topic: "text")
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
func parseTextRejectsFlagsItDoesNotDefine() {
    // `--duration` / `--velocity` aren't `text` modifiers. They are
    // refused rather than typed, so a caller who reached for the wrong
    // verb's flag hears about it instead of sending it to the device.
    for argv in [
        ["text", "--duration", "100"],
        ["text", "hello", "--velocity", "fast"]
    ] {
        guard case .usage = CLICommands.parse(["deviceterm"] + argv) else {
            Issue.record("expected .usage for \(argv)")
            return
        }
    }
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

@Test(
    "coordinates outside the unit range are usage errors",
    arguments: [
        ["deviceterm", "tap", "5", "5"],
        ["deviceterm", "tap", "0.5", "-0.2"],
        ["deviceterm", "long-press", "1.5", "0.5"],
        ["deviceterm", "swipe", "0.1", "0.1", "0.9", "42"],
        ["deviceterm", "pinch", "0.4", "0.4", "0.6", "0.6", "0.2", "0.2", "0.8", "9"],
        ["deviceterm", "ax", "point", "0.5", "2"]
    ]
)
func coordinatesOutsideTheUnitRangeAreUsage(argv: [String]) {
    // `ax tree` frames are displayed points. A frame value substituted for a
    // normalized coordinate must fail before dispatch.
    guard case .usage = CLICommands.parse(argv) else {
        Issue.record("out-of-range coordinates should be .usage: \(argv)")
        return
    }
}

@Test(
    "non-finite coordinates are usage errors",
    arguments: ["nan", "NaN", "inf", "-inf", "infinity"]
)
func nonFiniteCoordinatesAreUsage(token: String) {
    // `Double` parses all of these. The obvious guard spelling misses NaN,
    // which compares false against both bounds, so a comparison chain would
    // pass it straight through to the daemon.
    #expect(Double(token) != nil)
    guard case .usage = CLICommands.parse(["deviceterm", "tap", token, "0.5"]) else {
        Issue.record("non-finite coordinate should be .usage: \(token)")
        return
    }
}

@Test
func theUnitRangeBoundsThemselvesAreAccepted() {
    // Inclusive, and it has to stay inclusive: the daemon emits
    // `normalizedCenter` with the same inclusive test, so an edge control
    // centres on exactly 0 or 1 legitimately. Tightening this to exclusive
    // would refuse a coordinate `ax tree` had just reported.
    #expect(
        CLICommands.parse(["deviceterm", "tap", "0", "0"])
        == .tap(pane: nil, x: 0, y: 0)
        )
    #expect(
        CLICommands.parse(["deviceterm", "tap", "1", "1"])
        == .tap(pane: nil, x: 1, y: 1)
        )
    #expect(
        CLICommands.parse(["deviceterm", "ax", "point", "0", "1"])
        == .axPoint(pane: nil, x: 0, y: 1)
        )
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
func parseWaitPaneUsesDefaultDeadline() {
    #expect(
        CLICommands.parse(["deviceterm", "wait", "pane", "rendering"])
            == .waitPane(pane: nil, state: .rendering, timeoutMs: 30_000)
    )
}

@Test
func parseWaitPaneAcceptsTargetAndDeadline() {
    #expect(
        CLICommands.parse([
            "deviceterm", "wait", "pane", "shutdown",
            "--pane", "phone", "--timeout", "2500"
        ]) == .waitPane(pane: "phone", state: .shutdown, timeoutMs: 2_500)
    )
}

@Test
func parseWaitOrientationNormalizesTheValue() {
    #expect(
        CLICommands.parse(["deviceterm", "wait", "orientation", "landscape-left"])
            == .waitOrientation(pane: nil, orientation: .landscapeLeft, timeoutMs: 30_000)
    )
}

@Test
func parseWaitAXIdentifierDefaultsToTree() {
    let query = CLICommand.WaitAXQuery(
        identifier: "save",
        label: nil,
        role: nil,
        value: nil,
        matchMode: .exact,
        source: .tree,
        step: nil,
        budgetMs: nil
    )
    #expect(
        CLICommands.parse(["deviceterm", "wait", "ax", "--identifier", "save"])
            == .waitAX(pane: nil, query: query, timeoutMs: 30_000, printMode: nil, state: .present)
    )
}

@Test
func parseWaitAXSweepCarriesItsProbeOptions() {
    let query = CLICommand.WaitAXQuery(
        identifier: nil,
        label: "Save",
        role: "Button",
        value: nil,
        matchMode: .exact,
        source: .sweep,
        step: 0.2,
        budgetMs: 800
    )
    #expect(
        CLICommands.parse([
            "deviceterm", "wait", "ax", "--label", "Save", "--role", "Button",
            "--source", "sweep", "--step", "0.2", "--budget", "800"
        ]) == .waitAX(pane: nil, query: query, timeoutMs: 30_000, printMode: nil, state: .present)
    )
}

@Test("wait ax takes a substring match mode", arguments: [
    ["deviceterm", "wait", "ax", "--identifier", "save", "--match", "contains"],
    ["deviceterm", "wait", "ax", "--label", "Save", "--match", "contains"]
])
func parseWaitAXCarriesTheMatchMode(argv: [String]) {
    let query = CLICommand.WaitAXQuery(
        identifier: argv.contains("--identifier") ? "save" : nil,
        label: argv.contains("--label") ? "Save" : nil,
        role: nil,
        value: nil,
        matchMode: .contains,
        source: .tree,
        step: nil,
        budgetMs: nil
    )
    #expect(
        CLICommands.parse(argv)
            == .waitAX(
                pane: nil,
                query: query,
                timeoutMs: 30_000,
                printMode: nil,
                state: .present
            )
    )
}

@Test
func parseWaitAXCarriesTheValueFilter() {
    // `--value` is an optional conjunct; the existing exactly-one check
    // still requires a primary selector.
    let query = CLICommand.WaitAXQuery(
        identifier: nil,
        label: "Email",
        role: nil,
        value: "probe@example.com",
        matchMode: .exact,
        source: .tree,
        step: nil,
        budgetMs: nil
    )
    #expect(
        CLICommands.parse([
            "deviceterm", "wait", "ax", "--label", "Email",
            "--value", "probe@example.com"
        ]) == .waitAX(pane: nil, query: query, timeoutMs: 30_000, printMode: nil, state: .present)
    )
}

@Test(
    "invalid waits are usage failures",
    arguments: [
        ["deviceterm", "wait"],
        ["deviceterm", "wait", "pane", "settled"],
        ["deviceterm", "wait", "orientation", "diagonal"],
        ["deviceterm", "wait", "ax"],
        ["deviceterm", "wait", "ax", "--identifier", "save", "--label", "Save"],
        ["deviceterm", "wait", "ax", "--identifier", "save", "--source", "pixels"],
        ["deviceterm", "wait", "ax", "--identifier", "save", "--step", "0.2"],
        ["deviceterm", "wait", "ax", "--identifier", "save", "--match", "fuzzy"],
        ["deviceterm", "wait", "ax", "--label", "", "--match", "contains"],
        ["deviceterm", "wait", "ax", "--label", "Save", "--value", "", "--match", "contains"],
        ["deviceterm", "wait", "ax", "--identifier", "", "--match", "contains"],
        ["deviceterm", "wait", "pane", "rendering", "--timeout", "0"],
        ["deviceterm", "wait", "pane", "rendering", "--timeout", "soon"]
    ]
)
func invalidWaitIsUsage(argv: [String]) {
    guard case .usage = CLICommands.parse(argv) else {
        Issue.record("expected usage for \(argv)")
        return
    }
}

@Test
func parseWaitAXCarriesTheAbsentState() {
    let query = CLICommand.WaitAXQuery(
        identifier: nil,
        label: "Saving",
        role: nil,
        value: nil,
        matchMode: .exact,
        source: .tree,
        step: nil,
        budgetMs: nil
    )
    #expect(
        CLICommands.parse([
            "deviceterm", "wait", "ax", "--label", "Saving", "--state", "absent"
        ]) == .waitAX(
            pane: nil,
            query: query,
            timeoutMs: 30_000,
            printMode: nil,
            state: .absent
        )
    )
}

@Test(
    "invalid --state combinations are usage failures",
    arguments: [
        ["deviceterm", "wait", "ax", "--label", "X", "--state", "gone"],
        ["deviceterm", "wait", "ax", "--label", "X", "--state", "absent", "--print", "center"]
    ]
)
func invalidWaitAXStateIsUsage(argv: [String]) {
    // Printing a centre for something that is gone has nothing to print, and
    // succeeding with empty stdout is indistinguishable from a refusal.
    guard case .usage = CLICommands.parse(argv) else {
        Issue.record("expected usage for \(argv)")
        return
    }
}

// MARK: - Tapping by selector

@Test
func parseTapBySelectorTakesTheWaitAXGrammar() {
    let query = CLICommand.WaitAXQuery(
        identifier: nil,
        label: "Continue",
        role: "Button",
        value: nil,
        matchMode: .contains,
        source: .tree,
        step: nil,
        budgetMs: nil
    )
    #expect(
        CLICommands.parse([
            "deviceterm", "tap", "--label", "Continue",
            "--role", "Button", "--match", "contains"
        ]) == .tapElement(pane: nil, query: query, timeoutMs: 30_000)
    )
}

@Test
func parseTapBySelectorSweeps() {
    // Web content is invisible to the tree walk, so a sweep is the primary
    // path there rather than an edge case, and `tap` has to reach it.
    let query = CLICommand.WaitAXQuery(
        identifier: "submit",
        label: nil,
        role: nil,
        value: nil,
        matchMode: .exact,
        source: .sweep,
        step: 0.02,
        budgetMs: 20_000
    )
    #expect(
        CLICommands.parse([
            "deviceterm", "tap", "--identifier", "submit", "--source", "sweep",
            "--step", "0.02", "--budget", "20000", "--timeout", "5000"
        ]) == .tapElement(pane: nil, query: query, timeoutMs: 5_000)
    )
}

@Test
func aSelectorAndACoordinateAgreeOnWhatAQueryMeans() {
    // One parser behind both, so `--print center` and `tap` cannot come to
    // read the same flags as different queries.
    let selector = ["--label", "Continue", "--match", "contains", "--value", "on"]
    guard case let .waitAX(_, waitQuery, _, _, _) =
        CLICommands.parse(["deviceterm", "wait", "ax"] + selector),
        case let .tapElement(_, tapQuery, _) =
        CLICommands.parse(["deviceterm", "tap"] + selector) else {
        Issue.record("both verbs should parse the same selector")
        return
    }
    #expect(waitQuery == tapQuery)
}

@Test(
    "tap rejects a coordinate and a selector together",
    arguments: [
        ["deviceterm", "tap", "0.5", "0.5", "--label", "Continue"],
        ["deviceterm", "tap", "0.5", "--label", "Continue"],
        ["deviceterm", "tap", "--label", "A", "--identifier", "B"],
        ["deviceterm", "tap", "--label", "", "--match", "contains"],
        ["deviceterm", "tap", "--label", "A", "--source", "pixels"],
        ["deviceterm", "tap", "--label", "A", "--step", "0.2"],
        ["deviceterm", "tap", "--label", "A", "--match", "fuzzy"]
    ]
)
func invalidTapSelectorIsUsage(argv: [String]) {
    guard case .usage = CLICommands.parse(argv) else {
        Issue.record("expected usage for \(argv)")
        return
    }
}

@Test(
    "selector-only flags on a coordinate tap are usage errors",
    arguments: ["role", "value", "match", "source", "step", "budget", "timeout"]
)
func aCoordinateTapRefusesSelectorOnlyFlags(flag: String) {
    // Silently tapping the coordinates would run a command nobody wrote: the
    // flag is only there because the caller meant the selector form.
    guard case .usage = CLICommands.parse(
        ["deviceterm", "tap", "0.5", "0.5", "--\(flag)", "Button"]
    ) else {
        Issue.record("--\(flag) on a coordinate tap should be .usage")
        return
    }
}

@Test
func aPlainCoordinateTapIsUnchanged() {
    #expect(
        CLICommands.parse(["deviceterm", "tap", "0.5", "0.25", "--pane", "phn002"])
        == .tap(pane: "phn002", x: 0.5, y: 0.25)
    )
}

// MARK: - Waiting for surface quiescence

@Test
func parseWaitSurfaceQuiescentDefaultsItsSettleWindow() {
    #expect(
        CLICommands.parse(["deviceterm", "wait", "surface", "quiescent"])
        == .waitSurfaceQuiescent(pane: nil, settleMs: 500, timeoutMs: 30_000)
    )
}

@Test
func parseWaitSurfaceQuiescentCarriesItsFlags() {
    #expect(
        CLICommands.parse([
            "deviceterm", "wait", "surface", "quiescent",
            "--settle", "1200", "--timeout", "9000", "--pane", "phn001"
        ]) == .waitSurfaceQuiescent(pane: "phn001", settleMs: 1_200, timeoutMs: 9_000)
    )
}

@Test
func aZeroSettleParses() {
    // Zero is a legitimate ask: no window, just two agreeing observations.
    #expect(
        CLICommands.parse(["deviceterm", "wait", "surface", "quiescent", "--settle", "0"])
        == .waitSurfaceQuiescent(pane: nil, settleMs: 0, timeoutMs: 30_000)
    )
}

@Test(
    "invalid surface waits are usage failures",
    arguments: [
        ["deviceterm", "wait", "surface"],
        ["deviceterm", "wait", "surface", "still"],
        ["deviceterm", "wait", "surface", "quiescent", "--settle", "soon"],
        ["deviceterm", "wait", "surface", "quiescent", "--settle", "-1"]
    ]
)
func invalidSurfaceWaitIsUsage(argv: [String]) {
    guard case .usage = CLICommands.parse(argv) else {
        Issue.record("expected usage for \(argv)")
        return
    }
}

@Test
func aBareSurfaceWaitNamesItsOwnShape() throws {
    // `wait surface` alone is a half-typed command, not an unknown verb, so
    // the generic four-sub-verb line would answer a question nobody asked.
    guard case let .usage(message) = CLICommands.parse(
        ["deviceterm", "wait", "surface"]
    ) else {
        Issue.record("expected usage")
        return
    }
    let text = try #require(message)
    #expect(text.contains("wait surface quiescent"))
    #expect(!text.contains("wait <pane"))
}

// MARK: - Accessibility flags on a non-accessibility wait

@Test(
    "non-accessibility waits refuse accessibility flags",
    arguments: [
        ["--identifier", "save"],
        ["--label", "Save"],
        ["--role", "Button"],
        ["--value", "x"],
        ["--match", "contains"],
        ["--source", "sweep"],
        ["--print", "center"],
        ["--state", "absent"],
        ["--step", "0.2"],
        ["--budget", "500"]
    ]
)
func nonAXWaitsRefuseAccessibilityFlags(flag: [String]) {
    // `wait` registers these for the whole verb, so the parser accepts them
    // and every arm that cannot read them would otherwise drop them. A
    // dropped `--label` turns a wait for an element into a wait for the
    // pane, which succeeds without ever looking.
    for base in [
        ["deviceterm", "wait", "pane", "rendering"],
        ["deviceterm", "wait", "orientation", "portrait"],
        ["deviceterm", "wait", "surface", "quiescent"]
    ] {
        guard case .usage = CLICommands.parse(base + flag) else {
            Issue.record("expected usage for \(base + flag)")
            return
        }
    }
}

@Test(
    "--settle belongs to wait surface alone",
    arguments: [
        ["deviceterm", "wait", "pane", "rendering"],
        ["deviceterm", "wait", "orientation", "portrait"],
        ["deviceterm", "wait", "ax", "--label", "Save"]
    ]
)
func otherWaitsRefuseTheSettleFlag(base: [String]) throws {
    // The same rule the accessibility flags get, applied the other way: a
    // wait that cannot read `--settle` refuses rather than dropping it.
    guard case let .usage(message) = CLICommands.parse(base + ["--settle", "500"]) else {
        Issue.record("expected usage for \(base)")
        return
    }
    let text = try #require(message)
    #expect(text.contains("--settle"))
    #expect(text.contains("wait surface"))
}

@Test
func aStateFlagOnANonAXWaitIsRefusedByName() throws {
    // `--state` joins the same orphan set the moment it exists. Before the
    // guard this parsed and waited for pane rendering with the flag dropped,
    // which is the inverse of what the caller wrote.
    guard case let .usage(message) = CLICommands.parse(
        ["deviceterm", "wait", "pane", "rendering", "--state", "absent"]
    ) else {
        Issue.record("expected usage")
        return
    }
    let text = try #require(message)
    #expect(text.contains("--state"))
    #expect(text.contains("wait ax"))
}

@Test
func aStateFlagHoldingThePaneLifecycleGetsTheRightUsage() throws {
    // `wait pane --state rendering` is the natural mis-spelling: the flag
    // eats the lifecycle, leaving a lone `pane` positional. The generic wait
    // usage line explains that badly, so point at the shape the caller was
    // reaching for.
    guard case let .usage(message) = CLICommands.parse(
        ["deviceterm", "wait", "pane", "--state", "rendering"]
    ) else {
        Issue.record("expected usage")
        return
    }
    let text = try #require(message)
    #expect(text.contains("wait pane"))
    #expect(text.contains("rendering"))
    // Not the generic line, whose sub-verb list grows and would otherwise
    // make this assertion pass by having drifted.
    #expect(!text.contains("wait <pane"))
}

@Test
func aStateFlagHoldingSomethingElseKeepsTheGenericUsage() {
    // Only a value that names a lifecycle earns the targeted message. A
    // genuine typo has no business being told about `wait pane`.
    guard case let .usage(message) = CLICommands.parse(
        ["deviceterm", "wait", "pane", "--state", "nonsense"]
    ), message?.contains("wait <pane") == true else {
        Issue.record("expected the generic wait usage")
        return
    }
}

@Test
func nonAXWaitsStillTakeTheSharedFlags() {
    // The guard covers flags another wait owns. Every wait reads `--pane`
    // and `--timeout`, so neither may be caught by it.
    #expect(
        CLICommands.parse([
            "deviceterm", "wait", "pane", "rendering",
            "--pane", "phn001", "--timeout", "5000"
        ]) == .waitPane(pane: "phn001", state: .rendering, timeoutMs: 5_000)
    )
    #expect(
        CLICommands.parse([
            "deviceterm", "wait", "orientation", "portrait",
            "--pane", "phn001", "--timeout", "5000"
        ]) == .waitOrientation(pane: "phn001", orientation: .portrait, timeoutMs: 5_000)
    )
}

@Test
func theRefusalNamesTheWaitThatWasWritten() throws {
    // The likeliest cause is `pane` typed where `ax` was meant, so the
    // message has to name both the flag and the wait it landed on.
    guard case let .usage(message) = CLICommands.parse(
        ["deviceterm", "wait", "pane", "rendering", "--label", "Save"]
    ) else {
        Issue.record("expected usage")
        return
    }
    let text = try #require(message)
    #expect(text.contains("--label"))
    #expect(text.contains("wait ax"))
    #expect(text.contains("wait pane"))
}

@Test
func waitAXItselfStillTakesEveryAccessibilityFlag() {
    guard case .waitAX = CLICommands.parse([
        "deviceterm", "wait", "ax", "--label", "Save", "--role", "Button",
        "--match", "contains", "--source", "sweep", "--step", "0.2",
        "--budget", "500", "--timeout", "5000"
    ]) else {
        Issue.record("wait ax should accept its own flags")
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
func paneDeviceListRequestShape() throws {
    let envelope = try CLICommands.paneDeviceListRequest(sessionId: "SID", cap: "CAP")
    #expect(envelope.method == "pane.deviceList")
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
