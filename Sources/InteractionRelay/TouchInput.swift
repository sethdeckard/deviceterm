// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A touchscreen action.
package struct TouchInput: Sendable, Equatable {
    /// Whether this is a contact/press sample or the final lift.
    package enum Phase: Sendable, Equatable {
        case contact
        case lift
    }

    /// How the touch is routed on the device.
    package enum Kind: Sendable, Equatable {
        /// A plain digitizer touch, which reaches the foreground app.
        case direct
        /// A live edge drag carrying the system-gesture trailer, so it reaches
        /// SpringBoard's home-indicator recognizer instead of the app.
        case systemGesture(GestureEdge)
        /// The scripted App Switcher swipe from `edge` (grab → ramp → dwell →
        /// lift). The relay drives the whole trajectory; `point`/`phase` are
        /// ignored for this kind.
        case appSwitcher(GestureEdge)
    }

    package let point: DevicePoint
    package let phase: Phase
    package let kind: Kind
    /// Set only for `.appSwitcher`, whose trajectory is long enough to be worth
    /// abandoning partway. Excluded from `==`: it is control-plane state, so
    /// two inputs describing the same touch are equal whichever token they
    /// carry.
    package let cancellation: InteractionCancellation?

    package init(
        point: DevicePoint,
        phase: Phase,
        kind: Kind,
        cancellation: InteractionCancellation? = nil
    ) {
        self.point = point
        self.phase = phase
        self.kind = kind
        self.cancellation = cancellation
    }

    package static func == (lhs: TouchInput, rhs: TouchInput) -> Bool {
        lhs.point == rhs.point && lhs.phase == rhs.phase && lhs.kind == rhs.kind
    }
}
