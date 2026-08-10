// SPDX-License-Identifier: GPL-3.0-or-later
//
// ScrollMomentum ← NSEvent.Phase mapping. Lives in its own file so
// the pure `ScrollMods` namespace stays AppKit-free + Foundation-
// agnostic (Foundation+AppKit live here; the math lives in
// ScrollMods.swift). Tested as a small switch, since getting one case
// wrong silently breaks inertial scrolling for that phase only,
// which would be subtle to notice in manual QA.

import AppKit

extension ScrollMomentum {
    /// Translate an AppKit `NSEvent.Phase` (the value of `event.momentumPhase`
    /// for a scroll event) to the wire enum libghostty expects. Phases not
    /// recognized as a momentum phase (incl. the empty option set used between
    /// gestures) map to `.none`.
    static func from(_ phase: NSEvent.Phase) -> ScrollMomentum {
        switch phase {
        case .began:
            return .began

        case .stationary:
            return .stationary

        case .changed:
            return .changed

        case .ended:
            return .ended

        case .cancelled:
            return .cancelled

        case .mayBegin:
            return .mayBegin

        default:
            return .none
        }
    }
}
