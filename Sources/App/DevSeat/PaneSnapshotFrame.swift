// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One captured frame, as listed in a burst's `frames.json`: which file it
/// is, when it was drawn, and what the pane was drawing at the time.
struct PaneSnapshotFrame: Codable, Equatable {
    /// What the pane was drawing when a frame was taken.
    struct State: Codable, Equatable {
        /// For a frame taken after its pane went away.
        static let unknown = State(
            spansHinge: false,
            creased: false,
            drawnOrientation: "unknown",
            presentedOrientation: "unknown",
            surfaceWidth: 0,
            surfaceHeight: 0
        )

        /// The hinge angle the picture is drawn at, in degrees, nil for a
        /// device with no hinge or none reported yet.
        var hingeDegrees: Double?
        /// Whether the frame is from the panel the hinge runs through.
        var spansHinge: Bool
        /// Whether the picture is drawn bent at the hinge.
        var creased: Bool
        /// The orientation the picture is drawn in, and the one input goes
        /// out in.
        var drawnOrientation: String
        var presentedOrientation: String
        /// The frame's surface size, in pixels.
        var surfaceWidth: Int
        var surfaceHeight: Int
        /// For a foldable, whether the device is shown closed; nil while the
        /// pane has no frame to show (before the first, or while hidden) and
        /// for every other device.
        var shownClosed: Bool?
        /// Whether the whole device is drawn posed rather than the frame on
        /// show, and whether that's a turnover between the two sides.
        var drawsPosed = false
        var turningOver = false
    }

    let index: Int
    /// The PNG's file name in the burst's directory.
    let file: String
    /// Seconds from the start of the burst.
    let seconds: Double
    let state: State
}
