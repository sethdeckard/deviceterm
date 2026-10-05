// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Who takes a hit on a pane's SwiftUI chrome: SwiftUI, or the drag host
/// that rearranges the pane.
///
/// Pure, so every branch `PaneChromeHostingView.hitTest(_:)` can take is
/// testable without a hosting view. A hit the host keeps can start a pane
/// rearrange, so a branch that skips `interactiveOverride` turns a press on a
/// control into a lifted pane.
enum PaneChromeHitDecision {
    /// What SwiftUI's own hit test answered for the point.
    enum SwiftUIAnswer: Equatable, Sendable {
        /// A real subview, which only an interactive control produces.
        case subview
        /// The hosting view itself: SwiftUI drew something there but nothing
        /// interactive, or something interactive only through a gesture.
        case host
        /// Nothing, which is what a region under `.allowsHitTesting(false)`
        /// answers. Several chrome regions withhold their hits only in some
        /// states, so the same point can answer this on one press and
        /// `host` on the next.
        case none
    }

    enum Outcome: Equatable, Sendable {
        /// Return the subview SwiftUI found.
        case forward
        /// Keep the hit in the hosting view, so SwiftUI's gestures see it.
        case claim
        /// Hand the hit to the superview, the drag host.
        case passThrough
        /// Return nil, leaving AppKit's search of the siblings to settle it.
        case decline
    }

    /// Decide who takes the hit.
    ///
    /// `overrideClaims` is consulted whenever SwiftUI did not name a subview,
    /// whether it answered the host or nothing. Answering nothing is not a
    /// reason to skip the override: the regions that answer it are the ones
    /// a control withholds by state, and the override is what keeps those
    /// from the drag host.
    static func resolve(
        swiftUI answer: SwiftUIAnswer,
        overrideClaims: @autoclosure () -> Bool
    ) -> Outcome {
        switch answer {
        case .subview:
            return .forward

        case .host:
            return overrideClaims() ? .claim : .passThrough

        case .none:
            return overrideClaims() ? .claim : .decline
        }
    }
}
