// SPDX-License-Identifier: GPL-3.0-or-later
//
// Role protocol: pane teardown + input injection on the daemon.
//
// One of four narrow role protocols carved out of `DaemonClient`
// (see `SessionControlling` for the rationale). Covers `pane.close`
// and the whole `pane.input.*` family. Coordinates are normalized
// 0..1; `keyCode` is a raw `NSEvent.keyCode` (the daemon owns the
// kVK→HID translation).

import CoreGraphics
import DaemonProtocol

@MainActor
protocol PaneControlling: AnyObject {
    var supportsLiveTouchInput: Bool { get }
    /// Whether the daemon advertises `pane.input.multitouch`, the live
    /// two-finger (Option-drag pinch/rotate) stream. Gated separately
    /// from `supportsLiveTouchInput` so an older daemon degrades to
    /// single-touch without breaking.
    var supportsMultitouchInput: Bool { get }

    /// `pane.closeById` with `.detach` (sim keeps running) or `.shutdown`.
    /// `expecting` fences the close to one admission of the pane; see
    /// `DaemonClient.closePane`. Nil closes unconditionally.
    func closePane(paneId: String, mode: PaneCloseMode, expecting attachment: UInt64?) async throws
    func paneInputTap(paneId: String, x: Double, y: Double) async throws
    func paneInputTouch(
        paneId: String,
        x: Double,
        y: Double,
        phase: TouchPhase
    ) async throws
    func paneInputSwipe(
        paneId: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int,
        holdMs: Int,
        startHoldMs: Int
    ) async throws
    /// Edge-tagged drag for the simulator's system gestures (home
    /// indicator / App Switcher). `edge` is the raw `IndigoHIDEdge` value.
    func paneInputEdgeSwipe(
        paneId: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        edge: Int,
        durationMs: Int,
        holdMs: Int
    ) async throws
    /// `pane.input.edgeTouch`: a single edge-tagged live touch event, the
    /// per-event analogue of `paneInputTouch`. A live mouse drag from the
    /// displayed bottom edge streams these so the App Switcher follows the
    /// cursor. `edge` is the raw `IndigoHIDEdge` value (the simulator routes
    /// by it; the physical device by the system-gesture report trailer).
    func paneInputEdgeTouch(
        paneId: String,
        x: Double,
        y: Double,
        phase: TouchPhase,
        edge: Int
    ) async throws
    func paneInputLongPress(
        paneId: String,
        x: Double,
        y: Double,
        durationMs: Int
    ) async throws
    func paneInputKey(paneId: String, keyCode: UInt32, down: Bool) async throws
    func paneInputButton(paneId: String, button: HardwareButton) async throws
    func paneInputPinch(
        paneId: String,
        fromF1X: Double,
        fromF1Y: Double,
        fromF2X: Double,
        fromF2Y: Double,
        toF1X: Double,
        toF1Y: Double,
        toF2X: Double,
        toF2Y: Double,
        durationMs: Int
    ) async throws
    /// `pane.input.multitouch`: live two-finger contact frame, ordered
    /// finger 1, finger 2 (the client assigns the wire `id`s). Phases
    /// mirror the single-finger touch stream: `.down` starts contact,
    /// `.move` continues, `.lift` releases.
    func paneInputMultitouch(
        paneId: String,
        phase: TouchPhase,
        finger1: CGPoint,
        finger2: CGPoint
    ) async throws
    func paneInputText(paneId: String, text: String) async throws
    /// `pane.input.rotate`: rotate to an absolute orientation, or one
    /// 90° step from wherever the daemon believes the device is. The
    /// daemon resolves a direction, so Rotate Left/Right advances from
    /// the same value a `deviceterm rotate left` would.
    func paneInputRotate(paneId: String, target: RotationTarget) async throws
    /// `pane.input.crown`: watchOS Digital Crown rotation. `delta` is
    /// in the bridge's raw crown unit (~1 unit per detent); positive
    /// is forward/down. `durationMs == 0` sends the whole rotation
    /// at once; a positive value sub-steps it over the duration so a
    /// long scroll feels like a continuous turn instead of one jump.
    func paneInputCrown(paneId: String, delta: Double, durationMs: Int) async throws
}
