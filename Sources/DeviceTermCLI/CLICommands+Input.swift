// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Input command family: the gesture / hardware / text / accessibility
/// verbs (tap, swipe, app-switcher, long-press, pinch, button, key, text,
/// rotate, crown, ax) plus their request builders, split out of
/// CLICommands.swift to keep that file focused on the shared parse core.
///
/// `parse(_:)` (in CLICommands.swift) delegates the input verbs here through
/// `parseInputVerb`, which returns nil for any verb it doesn't own so the
/// caller falls through to a usage error. The read-only listing builders
/// (`tabsListRequest` / `panesListRequest`) ride along here too, next to
/// the input builders they resemble.
///
/// This is a behavior-grouping extension, not a conformance split. It
/// reaches the shared `request(method:body:)` helper and the
/// `parseEnumArg` / `parseKVKToken` token parsers, all `internal` in
/// CLICommands.swift.
extension CLICommands {
    // MARK: - Input verb parsing

    /// Parse an input-family verb (`tap` … `ax`) into its `CLICommand`,
    /// or return nil when `verb` is not an input verb (the caller then
    /// falls through to its own dispatch / usage error). The shared
    /// numeric flags are pre-validated and passed in already parsed:
    /// `durationMs` / `holdMs` / `velocity` / `step` / `budgetMs`. A
    /// malformed operand for an owned verb returns `.usage(...)` (not nil),
    /// so an input verb typed wrong never leaks to the fallthrough.
    static func parseInputVerb(
        _ verb: String,
        positionals pos: [String],
        pane: String?,
        durationMs: Int?,
        holdMs: Int?,
        velocity: Double?,
        step: Double?,
        budgetMs: Int?,
        flags: [String: String],
        timeoutMs: Int
    ) -> CLICommand? {
        switch verb {
        case "tap":
            guard pos.count == 2, let x = Double(pos[0]), let y = Double(pos[1]) else {
                return .usage(message: "usage: deviceterm tap <x> <y> [--pane <ref>]")
            }
            return .tap(pane: pane, x: x, y: y)

        case "swipe":
            let n = pos.compactMap { Double($0) }
            guard pos.count == 4, n.count == 4 else {
                return .usage(
                    message:
                    "usage: deviceterm swipe <fromX> <fromY> <toX> <toY> "
                    + "[--duration <ms>] [--hold <ms>] [--pane <ref>]"
                    )
            }
            return .swipe(
                pane: pane,
                fromX: n[0],
                fromY: n[1],
                toX: n[2],
                toY: n[3],
                durationMs: durationMs,
                holdMs: holdMs
                )

        case "app-switcher":
            guard pos.isEmpty else {
                return .usage(message: "usage: deviceterm app-switcher [--pane <ref>]")
            }
            return .appSwitcher(pane: pane)

        case "long-press":
            guard pos.count == 2, let x = Double(pos[0]), let y = Double(pos[1]) else {
                return .usage(
                    message:
                    "usage: deviceterm long-press <x> <y> [--duration <ms>] [--pane <ref>]"
                    )
            }
            return .longPress(pane: pane, x: x, y: y, durationMs: durationMs)

        case "pinch":
            let n = pos.compactMap { Double($0) }
            guard pos.count == 8, n.count == 8 else {
                return .usage(
                    message:
                    "usage: deviceterm pinch <f1x> <f1y> <f2x> <f2y> "
                    + "<tf1x> <tf1y> <tf2x> <tf2y> [--duration <ms>] [--pane <ref>]"
                    )
            }
            return .pinch(
                pane: pane,
                fromF1X: n[0],
                fromF1Y: n[1],
                fromF2X: n[2],
                fromF2Y: n[3],
                toF1X: n[4],
                toF1Y: n[5],
                toF2X: n[6],
                toF2Y: n[7],
                durationMs: durationMs
                )

        case "button":
            guard pos.count == 1,
                let button = parseEnumArg(pos[0], as: HardwareButton.self) else {
                return .usage(
                    message:
                    "usage: deviceterm button "
                    + "<home|lock|side|apple-pay|siri|digital-crown> [--pane <ref>]"
                    )
            }
            return .button(pane: pane, button: button)

        case "key":
            // Accept both decimal and `0x`-prefixed hex (Apple's
            // HIToolbox `kVK_*` constants are presented in hex in
            // the canonical headers, so an agent that looked up
            // "kVK_Tab = 0x30" should be able to type `0x30`).
            guard pos.count == 2, let keyCode = parseKVKToken(pos[0]),
                pos[1] == "down" || pos[1] == "up" else {
                return .usage(
                    message:
                    "usage: deviceterm key <keyCode> <down|up> [--pane <ref>] "
                    + "(decimal or 0x-prefixed hex)"
                    )
            }
            return .key(pane: pane, keyCode: keyCode, down: pos[1] == "down")

        case "text":
            guard !pos.isEmpty else {
                return .usage(message: "usage: deviceterm text <string> [--pane <ref>]")
            }
            return .text(pane: pane, text: pos.joined(separator: " "))

        case "rotate":
            // A direction and an orientation share one positional. Matching
            // is on the whole argument rather than a prefix, so no
            // orientation spelling resolves to `left` or `right` and the two
            // vocabularies can't shadow each other.
            guard pos.count == 1, let target = parseRotationTarget(pos[0]) else {
                return .usage(
                    message:
                    "usage: deviceterm rotate "
                    + "<portrait|portrait-upside-down|landscape-left|landscape-right"
                    + "|left|right> "
                    + "[--pane <ref>]"
                    )
            }
            return .rotate(pane: pane, target: target)

        case "crown":
            guard pos.count == 1, let delta = Double(pos[0]) else {
                return .usage(
                    message:
                    "usage: deviceterm crown <delta> [--velocity <v>] "
                    + "[--duration <ms>] [--pane <ref>]"
                    )
            }
            return .crown(pane: pane, delta: delta, velocity: velocity, durationMs: durationMs)

        case "ax":
            if pos == ["tree"] { return .axTree(pane: pane) }
            if pos.count == 3, pos[0] == "point",
                let x = Double(pos[1]), let y = Double(pos[2]) {
                return .axPoint(pane: pane, x: x, y: y)
            }
            if pos == ["sweep"] {
                return .axSweep(pane: pane, step: step, budgetMs: budgetMs)
            }
            return .usage(
                message:
                "usage: deviceterm ax tree | ax point <x> <y> "
                + "| ax sweep [--step <0..1>] [--budget <ms>] [--pane <ref>]"
                )

        case "wait":
            if pos.count == 2, pos[0] == "pane",
                let state = PaneLifecycle(rawValue: pos[1]) {
                return .waitPane(pane: pane, state: state, timeoutMs: timeoutMs)
            }
            if pos.count == 2, pos[0] == "orientation",
                let orientation = parseEnumArg(pos[1], as: Orientation.self) {
                return .waitOrientation(
                    pane: pane,
                    orientation: orientation,
                    timeoutMs: timeoutMs
                )
            }
            if pos == ["ax"] {
                let identifier = flags["identifier"]
                let label = flags["label"]
                guard (identifier == nil) != (label == nil) else {
                    return .usage(
                        message: "deviceterm: wait ax requires exactly one of --identifier or --label"
                    )
                }
                guard let matchMode = CLICommand.WaitAXMatchMode(rawValue: flags["match"] ?? "exact") else {
                    return .usage(message: "deviceterm: --match must be exact or contains")
                }
                // An empty needle is a legitimate exact query for an empty
                // attribute, but under `contains` it matches every
                // string-valued instance of that attribute.
                if matchMode == .contains, (identifier ?? label)?.isEmpty == true {
                    return .usage(
                        message: "deviceterm: --match contains requires a non-empty --identifier or --label"
                    )
                }
                guard let source = CLICommand.WaitAXSource(rawValue: flags["source"] ?? "tree") else {
                    return .usage(message: "deviceterm: --source must be tree or sweep")
                }
                if source == .tree, step != nil || budgetMs != nil {
                    return .usage(
                        message: "deviceterm: --step and --budget require --source sweep"
                    )
                }
                return .waitAX(
                    pane: pane,
                    query: .init(
                        identifier: identifier,
                        label: label,
                        role: flags["role"],
                        matchMode: matchMode,
                        source: source,
                        step: step,
                        budgetMs: budgetMs
                    ),
                    timeoutMs: timeoutMs
                )
            }
            return .usage(
                message: "usage: deviceterm wait <pane|ax|orientation> ... [--timeout <ms>]"
            )

        default:
            return nil
        }
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

    // MARK: - Input & listing request builders

    /// `deviceterm tabs list`: no params.
    public static func tabsListRequest() -> RPCEnvelope {
        RPCEnvelope(id: 1, type: .request, method: RPCMethod.tabsList.rawValue, body: .empty)
    }

    /// `deviceterm panes list`: session-scoped, so it carries credentials.
    public static func panesListRequest(sessionId: String, cap: String) throws -> RPCEnvelope {
        try request(method: .panesList, body: PanesListParams(sessionId: sessionId, cap: cap))
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
