// SPDX-License-Identifier: GPL-3.0-or-later
//
// MultitouchParams: wire shape for `pane.input.multitouch`.
//
// A live two-finger touch frame (Option-drag pinch/rotate). The daemon
// maps each point to a `CGPoint` in its handler, so the wire shape
// itself stays Foundation-only.

/// One contact in a live `pane.input.multitouch` frame. `id` is a
/// stable per-finger identity for forward-compat (future N-finger
/// support); the daemon keys off array order (`points[0]` = finger 1,
/// `points[1]` = finger 2).
public struct MultitouchPoint: Codable, Sendable {
    public let id: Int
    /// Normalized display coords; off-[0,1] values are passed to
    /// CoreSimulator as-is (mirrored fingers can land off-screen).
    public let x: Double
    public let y: Double

    public init(id: Int, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

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
