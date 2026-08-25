// SPDX-License-Identifier: GPL-3.0-or-later
//
// EdgeTouchParams: wire shape for `pane.input.edgeTouch`.
//
// A single edge-tagged live touch event, the per-event analogue of
// `TouchParams` for the simulator's system gestures. A live GUI mouse
// drag that starts in the displayed bottom edge band streams these
// (down -> moves -> lift) so the home indicator / App Switcher follows
// the cursor, where the scripted `edgeSwipe` plays a fixed trajectory.
// `edge` is the raw `IndigoHIDEdge` value identifying the originating
// screen edge.

public struct EdgeTouchParams: Codable, Sendable {
    public let paneId: String
    public let x: Double
    public let y: Double
    public let phase: String
    public let edge: Int

    public init(paneId: String, x: Double, y: Double, phase: String, edge: Int) {
        self.paneId = paneId
        self.x = x
        self.y = y
        self.phase = phase
        self.edge = edge
    }
}
