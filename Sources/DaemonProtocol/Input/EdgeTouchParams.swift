// SPDX-License-Identifier: GPL-3.0-or-later
//
// EdgeTouchParams: wire shape for `pane.input.edgeTouch`.
//
// A single edge-tagged live touch event, the per-event analogue of
// `TouchParams` for the simulator's system gestures. A live GUI mouse
// drag that starts in the displayed bottom edge band streams these
// (down -> moves -> lift) so the home indicator / App Switcher follows
// the cursor, where the scripted `edgeSwipe` plays a fixed trajectory.
// Coordinates are displayed space. The raw `IndigoHIDEdge` tag is not on
// the wire: it depends on the device's orientation, and the daemon
// resolves it from its authoritative presentation orientation rather
// than trusting a client snapshot that may be stale. It latches the tag
// with `edge(for:)` when the press arrives, and rotates every event of
// that contact through the same orientation.

public struct EdgeTouchParams: Codable, Sendable {
    public let paneId: String
    public let x: Double
    public let y: Double
    public let phase: String

    public init(paneId: String, x: Double, y: Double, phase: String) {
        self.paneId = paneId
        self.x = x
        self.y = y
        self.phase = phase
    }
}
