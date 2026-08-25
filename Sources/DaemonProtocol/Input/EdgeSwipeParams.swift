// SPDX-License-Identifier: GPL-3.0-or-later
//
// EdgeSwipeParams: wire shape for `pane.input.edgeSwipe`.
//
// An edge-tagged drag for the simulator's system gestures (home
// indicator / App Switcher). Coordinates are displayed space, as with
// the other coordinate-bearing touch verbs. The raw `IndigoHIDEdge` tag that lets the OS
// recognize the gesture is not on the wire: it depends on the device's
// orientation, and the daemon resolves it alongside the coordinate
// rotation (`AppSwitcherGesture.plan(for:)`) from its authoritative
// presentation orientation rather than a client snapshot.

public struct EdgeSwipeParams: Codable, Sendable {
    public let paneId: String
    public let fromX: Double
    public let fromY: Double
    public let toX: Double
    public let toY: Double
    public let durationMs: Int?
    public let holdMs: Int?

    public init(
        paneId: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int?,
        holdMs: Int?
    ) {
        self.paneId = paneId
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
        self.durationMs = durationMs
        self.holdMs = holdMs
    }
}
