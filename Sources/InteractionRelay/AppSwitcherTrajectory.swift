// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppSwitcherTrajectory: the scripted App Switcher swipe's geometry, separated
// from the relay that sends it.
//
// The relay owns channels and reports; none of that is needed to decide where
// each frame goes, and keeping the geometry here is what makes it testable
// without a live device channel.

import Foundation

enum AppSwitcherTrajectory {
    /// Every contact point the trajectory plays after the opening grab, in
    /// order: hold at the grab point, ramp toward the dwell point, hold there.
    static func points(
        grab: (x: UInt16, y: UInt16),
        dwell: (x: UInt16, y: UInt16),
        grabFrames: Int,
        rampFrames: Int,
        holdFrames: Int
    ) -> [(x: UInt16, y: UInt16)] {
        var points: [(x: UInt16, y: UInt16)] = []
        points.append(contentsOf: repeatElement(grab, count: max(0, grabFrames)))
        let ramp = max(1, rampFrames)
        for frame in 1...ramp {
            let fraction = Double(frame) / Double(ramp)
            points.append((lerp(grab.x, dwell.x, fraction), lerp(grab.y, dwell.y, fraction)))
        }
        points.append(contentsOf: repeatElement(dwell, count: max(0, holdFrames)))
        return points
    }

    private static func lerp(_ start: UInt16, _ end: UInt16, _ fraction: Double) -> UInt16 {
        UInt16((Double(start) + (Double(end) - Double(start)) * fraction).rounded())
    }
}
