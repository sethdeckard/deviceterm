// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The motion of a foldable turning over between its panels, as a pose for
/// each moment.
///
/// Fitted to Device Hub's frames at 60 fps. Closing, the folded device first
/// yaws as one piece until the fixed half faces the viewer, then the swinging
/// half keeps going round and lands on it cover out. Opening runs the same two
/// phases backwards: the cover swings away about its hinge, then the fold
/// yaws back to symmetric at the hinge's angle. The scene keeps the device
/// centred throughout (`FoldTurnoverScene`), so neither phase carries a
/// slide.
enum FoldTurnover {
    enum Direction: Equatable {
        /// From the inner panel to the cover.
        case closing
        /// From the cover to the inner panel.
        case opening
    }

    /// The whole motion, in seconds.
    static let duration: Double = 0.4
    /// The yaw's share of the motion, which Device Hub spends about a
    /// quarter of its turnover on.
    static let yawShare = 0.28
    /// The hinge angles, in degrees, a fold reaches to turn the device over:
    /// opening at or above `opensAbove`, closing at or below `closesBelow`.
    /// Device Hub's, read off its frames. The gap between them keeps a hinge
    /// resting near either from turning the device back and forth.
    static let opensAbove: Double = 55
    static let closesBelow: Double = 44

    /// Whether to show the device closed.
    ///
    /// The hinge decides, as it does in Device Hub, whichever panel iOS has
    /// lit: iOS moves the lit panel at angles of its own, well past these, and
    /// sometimes not at all, and a panel it hasn't lit shows black rather than
    /// the device flipping to the other side.
    /// `wasClosed` is what was shown, nil before anything was. With nothing
    /// shown yet, or no hinge reading (`hinge` nil), the lit panel decides.
    static func showsClosed(wasClosed: Bool?, hinge degrees: Double?, coverLit: Bool) -> Bool {
        guard let wasClosed, let degrees else { return coverLit }
        return wasClosed ? degrees < opensAbove : degrees <= closesBelow
    }

    /// The pose `elapsed` seconds into a turnover between the open fold at
    /// `openTurn` and the device shown closed with its hinge at `closedHinge`
    /// radians (`FoldPose.closed(hinge:)`).
    static func pose(direction: Direction, elapsed: Double, openTurn: Double, closedHinge: Double = 0) -> FoldPose {
        let progress = min(max(elapsed / duration, 0), 1)
        return closingPose(
            progress: direction == .closing ? progress : 1 - progress,
            openTurn: openTurn,
            closedHinge: closedHinge
        )
    }

    /// The fit to draw at `elapsed` seconds in, between the open fold's
    /// `openScale` and the closed device's, which is the cover's resting
    /// scale, `1`. Moved with the motion, so neither end jumps against the
    /// steady drawing either side of it.
    static func scale(openScale: Double, direction: Direction, elapsed: Double) -> Double {
        let progress = min(max(elapsed / duration, 0), 1)
        let closedness = direction == .closing ? progress : 1 - progress
        return openScale + (1 - openScale) * closedness
    }

    /// Whether a turnover `elapsed` seconds in has finished.
    static func isFinished(elapsed: Double) -> Bool { elapsed >= duration }

    /// The motion at `progress`, `0` the open fold and `1` closed. Opening is
    /// this run backwards.
    static func closingPose(progress: Double, openTurn: Double, closedHinge: Double = 0) -> FoldPose {
        if progress < yawShare {
            // One rigid piece: what the fixed half gives up, the swinging half
            // takes, so the angle between them holds.
            let eased = ease(progress / yawShare)
            return FoldPose(fixedTurn: openTurn * (1 - eased), swingTurn: openTurn * (1 + eased))
        }
        let eased = ease((progress - yawShare) / (1 - yawShare))
        let closed = FoldPose.closed(hinge: closedHinge)
        return FoldPose(
            fixedTurn: closed.fixedTurn * eased,
            swingTurn: 2 * openTurn + (closed.swingTurn - 2 * openTurn) * eased
        )
    }

    /// Smoothstep: no jolt at either end of a phase.
    private static func ease(_ fraction: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
