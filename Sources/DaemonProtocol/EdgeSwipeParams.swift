// SPDX-License-Identifier: GPL-3.0-or-later
//
// EdgeSwipeParams: wire shape for `pane.input.edgeSwipe`.
//
// An edge-tagged drag for the simulator's system gestures (home
// indicator / App Switcher). `edge` is the raw `IndigoHIDEdge` value
// identifying the originating screen edge. Where a plain swipe plays a
// fixed trajectory, the edge tag lets the OS recognize the system
// gesture.

public struct EdgeSwipeParams: Codable, Sendable {
    public let paneId: String
    public let fromX: Double
    public let fromY: Double
    public let toX: Double
    public let toY: Double
    public let edge: Int
    public let durationMs: Int?
    public let holdMs: Int?

    public init(
        paneId: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        edge: Int,
        durationMs: Int?,
        holdMs: Int?
    ) {
        self.paneId = paneId
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
        self.edge = edge
        self.durationMs = durationMs
        self.holdMs = holdMs
    }
}
