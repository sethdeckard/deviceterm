// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Testing

/// The orientation and edge tag a scripted App Switcher swipe plays with.
/// The tag names the native edge the contacts originate from and the
/// coordinates have to land on that same edge, so the two are resolved
/// together; a pair that disagrees arms nothing.
struct AppSwitcherGesturePlanTests {
    /// A dwell at mid-screen can already have committed the edge gesture to
    /// Home. Keep the pause in the shallow switcher band used by the proven
    /// physical-device trajectory instead.
    @Test
    func simulatorTrajectoryDwellsBeforeTheHomeCommitThreshold() {
        #expect(AppSwitcherGesture.fromY == 0.99)
        #expect(AppSwitcherGesture.toY == 0.78)
        #expect(AppSwitcherGesture.fromY - AppSwitcherGesture.toY < 0.25)
        #expect(AppSwitcherGesture.holdMs > 0)
    }

    /// Each orientation plays in its own frame, tagged with its own
    /// live-confirmed edge value.
    @Test(
        "plan per orientation",
        arguments: [
            (Orientation.portrait, Orientation.portrait, 3),
            (.landscapeLeft, .landscapeLeft, 2),
            (.landscapeRight, .landscapeRight, 4)
        ]
    )
    func planKeepsConfirmedOrientations(
        orientation: Orientation,
        expected: Orientation,
        edge: Int
    ) {
        let plan = AppSwitcherGesture.plan(for: orientation)
        #expect(plan.orientation == expected)
        #expect(plan.edge == edge)
    }

    /// Upside-down has no confirmed home-gesture edge, so it degrades to
    /// the portrait gesture wholesale rather than tagging a 180°-rotated
    /// swipe with the portrait edge. A tag and a trajectory that
    /// disagree about which edge the contact came from arm nothing.
    @Test
    func upsideDownFallsBackToPortraitWholesale() {
        let plan = AppSwitcherGesture.plan(for: .portraitUpsideDown)
        #expect(plan.orientation == .portrait)
        #expect(plan.edge == AppSwitcherGesture.edge)
    }
}
