// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Input command family: the gesture / hardware / text / accessibility
/// verbs (tap, swipe, app-switcher, long-press, pinch, button, key, text,
/// rotate, crown, ax) plus their request builders, split out of
/// CLICommands.swift to keep that file focused on the shared parse core.
///
/// The input verbs parse from their own declarations under `Commands/`;
/// what remains here is the request encoding they share, plus the
/// coordinate and selector checks a declaration cannot state. The
/// read-only listing builders
/// The internal device-pane roster request rides along here too, next to
/// the input builders they resemble.
///
/// This is a behavior-grouping extension, not a conformance split. It
/// reaches the shared `request(method:body:)` helper and the
/// `parseEnumArg` / `parseKVKToken` token parsers, all `internal` in
/// CLICommands.swift.
extension CLICommands {
    // MARK: - Accessibility selector grammar

    /// The result of reading an accessibility selector off a verb's flags.
    ///
    /// A plain optional would collapse every rejection into one, and the
    /// selector has six distinct ways to be wrong, each with its own message.
    enum AXSelectorParse {
        case query(CLICommand.WaitAXQuery)
        case usage(String)
    }

    /// Both forms of `tap`, which take either operand but never both.
    ///
    /// The bare shape, with no `usage:` opener: the help page prepends
    /// its own label and `usageRefusal` prepends the refusal's, so
    /// carrying one here would double it in both. The continuation is
    /// indented to clear either label, both being seven columns.
    static let tapUsage = """
    deviceterm tap <x> <y> [--pane <ref>]
           deviceterm tap (--identifier <value>|--label <value>) [--role <value>] \
    [--value <value>] [--match <exact|contains>] [--source <tree|sweep>] \
    [--step <0..1>] [--budget <ms>] [--timeout <ms>] [--pane <ref>]
    """

    /// The flags each `wait` sub-verb reads on its own, keyed by sub-verb.
    ///
    /// `wait` registers the union for the whole verb, so the parser accepts
    /// any of them under any sub-verb and each arm has to refuse the ones
    /// belonging to another. `--pane` and `--timeout` are absent because
    /// every wait reads both.
    ///
    /// A wait picks its form from the sub-verb, so nothing here selects
    /// a form and everything is an orphan somewhere else. `TapCommand`
    /// carries its own list for the opposite case, where `--identifier`
    /// and `--label` are what pick the form.
    ///
    /// `--step` and `--budget` reach the check already converted, so
    /// `foreignWaitFlagRefusal` checks them as values rather than by name.
    static let waitExclusiveFlags: [String: [String]] = [
        "ax": [
            "identifier", "label", "role", "value", "match", "source",
            "print", "state"
        ],
        "surface": ["settle"]
    ]

    // MARK: - Shared grammar checks

    /// The usage error for a wait carrying a flag another wait owns, or nil
    /// when every flag it was given belongs to it.
    ///
    /// Refusing rather than dropping, because dropping is not harmless.
    /// `wait pane rendering --label Save` reads as a wait for a labelled
    /// element and is a wait for the pane, reporting success without having
    /// looked for the label at all.
    ///
    /// Owners are visited in sorted order so the same argv always names the
    /// same flag.
    static func foreignWaitFlagRefusal(
        subVerb: String,
        flags: [String: String],
        step: Double?,
        budgetMs: Int?
    ) -> CLICommand? {
        func refusal(_ flag: String, owner: String) -> CLICommand {
            .usage(
                message: "deviceterm: --\(flag) applies to `wait \(owner)`, "
                    + "not `wait \(subVerb)`"
            )
        }
        for owner in waitExclusiveFlags.keys.sorted() where owner != subVerb {
            if let named = waitExclusiveFlags[owner]?.first(where: { flags[$0] != nil }) {
                return refusal(named, owner: owner)
            }
        }
        guard subVerb != "ax" else { return nil }
        if step != nil { return refusal("step", owner: "ax") }
        if budgetMs != nil { return refusal("budget", owner: "ax") }
        return nil
    }

    /// The first coordinate outside the inclusive unit range, or nil when
    /// every one is acceptable.
    ///
    /// Written as `ClosedRange.contains` rather than a comparison chain
    /// because NaN compares false against both bounds: `v < 0 || v > 1`
    /// admits it, and `Double("nan")` parses. Infinity fails the upper bound
    /// under either spelling.
    ///
    /// The range is inclusive to match `normalizedCenter`, which the daemon
    /// emits with the same inclusive test. An edge control legitimately
    /// centres on 0 or 1, so tightening this to exclusive would refuse a
    /// coordinate DeviceTerm had just handed the caller.
    static func firstCoordinateOutsideUnitRange(_ values: [Double]) -> Double? {
        values.first { !(0...1).contains($0) }
    }

    /// The usage error for a coordinate outside the unit range.
    ///
    /// Mentions points because an `ax tree` frame can be mistaken for a
    /// normalized coordinate. An out-of-range value has to fail before
    /// dispatch.
    static func coordinateRangeUsage(_ value: Double) -> String {
        "deviceterm: coordinates are normalized 0..1, got \(value); "
            + "`ax tree` frames are in points, so pass `normalizedCenter`"
    }

    /// Resolve `rotate`'s single positional to a direction or an
    /// absolute orientation, nil when it is neither. Both go through the
    /// shared enum-argument normalization, which for the single-word
    /// directions amounts to accepting any capitalization.
    static func parseRotationTarget(_ raw: String) -> RotationTarget? {
        if let direction = parseEnumArg(raw, as: RotationDirection.self) {
            return .relative(direction)
        }
        if let orientation = parseEnumArg(raw, as: Orientation.self) {
            return .absolute(orientation)
        }
        return nil
    }

    /// A posture name or a bare angle, resolved to degrees. Nil when the
    /// token is neither, or names an angle outside the hinge's range.
    ///
    /// Names are matched before numbers so a posture can never be read as a
    /// partially-parsed figure.
    static func parseFoldPosture(_ raw: String) -> Double? {
        if let posture = FoldPosture.named(raw) { return posture.degrees }
        guard let degrees = Double(raw),
            FoldPosture.degreeRange.contains(degrees) else { return nil }
        return degrees
    }

    // MARK: - Input & listing request builders

    /// Daemon-direct device-pane roster used to resolve device-control verbs.
    public static func paneDeviceListRequest(sessionId: String, cap: String) throws -> RPCEnvelope {
        try request(method: .paneDeviceList, body: PanesListParams(sessionId: sessionId, cap: cap))
    }

    public static func tapRequest(paneId: String, x: Double, y: Double) throws -> RPCEnvelope {
        try request(method: .paneInputTap, body: TapParams(paneId: paneId, x: x, y: y))
    }

    public static func swipeRequest(
        paneId: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int?,
        holdMs: Int? = nil,
        startHoldMs: Int? = nil
    ) throws -> RPCEnvelope {
        try request(
            method: .paneInputSwipe,
            body: SwipeParams(
            paneId: paneId,
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            durationMs: durationMs,
            holdMs: holdMs,
            startHoldMs: startHoldMs
        )
            )
    }

    public static func edgeSwipeRequest(
        paneId: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int?,
        holdMs: Int?
    ) throws -> RPCEnvelope {
        try request(
            method: .paneInputEdgeSwipe,
            body: EdgeSwipeParams(
            paneId: paneId,
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            durationMs: durationMs,
            holdMs: holdMs
        )
            )
    }

    public static func longPressRequest(
        paneId: String,
        x: Double,
        y: Double,
        durationMs: Int?
    ) throws -> RPCEnvelope {
        try request(
            method: .paneInputLongPress,
            body: LongPressParams(
            paneId: paneId,
            x: x,
            y: y,
            durationMs: durationMs
        )
            )
    }

    public static func pinchRequest(
        paneId: String,
        fromF1X: Double,
        fromF1Y: Double,
        fromF2X: Double,
        fromF2Y: Double,
        toF1X: Double,
        toF1Y: Double,
        toF2X: Double,
        toF2Y: Double,
        durationMs: Int?
    ) throws -> RPCEnvelope {
        try request(
            method: .paneInputPinch,
            body: PinchParams(
            paneId: paneId,
            fromF1X: fromF1X,
            fromF1Y: fromF1Y,
            fromF2X: fromF2X,
            fromF2Y: fromF2Y,
            toF1X: toF1X,
            toF1Y: toF1Y,
            toF2X: toF2X,
            toF2Y: toF2Y,
            durationMs: durationMs
        )
            )
    }

    public static func buttonRequest(paneId: String, button: HardwareButton) throws -> RPCEnvelope {
        try request(method: .paneInputButton, body: ButtonParams(paneId: paneId, button: button.rawValue))
    }

    public static func keyRequest(paneId: String, keyCode: UInt32, down: Bool) throws -> RPCEnvelope {
        try request(
            method: .paneInputKey,
            body: KeyParams(
            paneId: paneId,
            keyCode: keyCode,
            down: down
        )
            )
    }

    public static func textRequest(paneId: String, text: String) throws -> RPCEnvelope {
        try request(method: .paneInputText, body: TextParams(paneId: paneId, text: text))
    }

    public static func rotateRequest(paneId: String, target: RotationTarget) throws -> RPCEnvelope {
        try request(
            method: .paneInputRotate,
            body: RotateParams(
            paneId: paneId,
            target: target
        )
            )
    }

    public static func foldRequest(
        paneId: String,
        degrees: Double
    ) throws -> RPCEnvelope {
        try request(
            method: .paneInputFold,
            body: FoldParams(paneId: paneId, degrees: degrees)
        )
    }

    public static func crownRequest(
        paneId: String,
        delta: Double,
        velocity: Double?,
        durationMs: Int?
    ) throws -> RPCEnvelope {
        try request(
            method: .paneInputCrown,
            body: CrownParams(
            paneId: paneId,
            delta: delta,
            velocity: velocity,
            durationMs: durationMs
        )
            )
    }

    public static func axTreeRequest(paneId: String) throws -> RPCEnvelope {
        try request(method: .paneAXTree, body: AXTreeParams(paneId: paneId))
    }

    public static func axPointRequest(paneId: String, x: Double, y: Double) throws -> RPCEnvelope {
        try request(method: .paneAXPoint, body: AXPointParams(paneId: paneId, x: x, y: y))
    }

    public static func axSweepRequest(
        paneId: String,
        step: Double?,
        budgetMs: Int?
    ) throws -> RPCEnvelope {
        try request(
            method: .paneAXSweep,
            body: AXSweepParams(paneId: paneId, step: step, budgetMs: budgetMs)
        )
    }
}
