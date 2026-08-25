// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwipeParams: wire shape for `pane.input.swipe`.
//
// A scripted swipe: interpolated motion from a start point to an end
// point, with optional active dwells at each end.

public struct SwipeParams: Codable, Sendable {
    public let paneId: String
    public let fromX: Double
    public let fromY: Double
    public let toX: Double
    public let toY: Double
    /// Optional, defaults to `swipeDefaultDurationMs` (200ms).
    public let durationMs: Int?
    /// Optional dwell at the END point, *after* the interpolated
    /// motion and *before* the lift, defaulting to 0 (no dwell).
    /// Unlike a passive sleep, the daemon **re-reports contact at
    /// the end point every frame** for this long, so the OS sees the
    /// finger decelerate to a stop while still down, the signature
    /// the iOS app-switcher / Control-Center recognizers need that a
    /// plain swipe-and-lift can't express.
    public let holdMs: Int?
    /// Optional dwell at the START point, *after* the initial contact
    /// and *before* the motion, defaulting to 0. Same active
    /// re-report as `holdMs`. Lets the OS lock onto a bottom-edge
    /// system gesture (the "grab the handle" moment) before the drag
    /// begins. Without it a synthetic swipe pulls away the instant
    /// it touches down and the edge-pan never starts tracking.
    public let startHoldMs: Int?

    public init(
        paneId: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int?,
        holdMs: Int?,
        startHoldMs: Int?
    ) {
        self.paneId = paneId
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
        self.durationMs = durationMs
        self.holdMs = holdMs
        self.startHoldMs = startHoldMs
    }
}
