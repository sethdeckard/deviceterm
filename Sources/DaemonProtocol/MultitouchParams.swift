// SPDX-License-Identifier: GPL-3.0-or-later
//
// MultitouchParams: wire shape for `pane.input.multitouch`.
//
// A live two-finger touch frame (Option-drag pinch/rotate). The daemon
// maps each point to a `CGPoint` in its handler, so the wire shape
// itself stays Foundation-only.

public struct MultitouchParams: Codable, Sendable {
    public let paneId: String
    /// `down` | `move` | `up`, the same `TouchPhase` vocabulary as the
    /// single-finger `pane.input.touch` stream.
    public let phase: String
    /// Exactly two contacts (the bridge is two-finger).
    public let points: [MultitouchPoint]

    public init(paneId: String, phase: String, points: [MultitouchPoint]) {
        self.paneId = paneId
        self.phase = phase
        self.points = points
    }
}
