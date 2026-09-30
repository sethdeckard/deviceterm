// SPDX-License-Identifier: GPL-3.0-or-later

/// `pane.subscribe` event `hinge.changed`. Carries an observed hinge angle,
/// including the current one replayed to a new subscriber, and a fold made
/// outside DeviceTerm.
///
/// An observation of the device, not a receipt for a `pane.input.fold`. The
/// daemon watches the hinge and publishes what it reads, so a subscriber can
/// show the angle the device is at rather than the last one asked for.
public struct HingeChangedEvent: Codable, Sendable, Equatable {
    public let paneId: String
    /// Hinge angle in degrees, `0` shut and `180` flat, matching the
    /// `pane.input.fold` wire convention.
    public let degrees: Double

    public init(paneId: String, degrees: Double) {
        self.paneId = paneId
        self.degrees = degrees
    }
}
