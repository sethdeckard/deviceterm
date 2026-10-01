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
    /// Whether the panel the pane is showing is the one the hinge runs
    /// through, so its picture bends as the angle changes.
    ///
    /// False for a foldable's cover panel, which sits outside the fold and
    /// stays flat at every angle, and false on a device with one panel. The
    /// angle alone cannot answer this: which panel is lit depends on the path
    /// the hinge took rather than where it stopped, so the same angle occurs
    /// with either panel showing.
    ///
    /// Republished whenever the lit panel moves, since a fold changes this
    /// after the angle has stopped moving.
    public let spansHinge: Bool

    public init(paneId: String, degrees: Double, spansHinge: Bool) {
        self.paneId = paneId
        self.degrees = degrees
        self.spansHinge = spansHinge
    }

    /// Absent `spansHinge` decodes as `false`, so a peer that predates the
    /// field claims no hinge-spanning panel rather than having one assumed
    /// on its behalf.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneId = try container.decode(String.self, forKey: .paneId)
        degrees = try container.decode(Double.self, forKey: .degrees)
        spansHinge = try container.decodeIfPresent(Bool.self, forKey: .spansHinge) ?? false
    }
}
