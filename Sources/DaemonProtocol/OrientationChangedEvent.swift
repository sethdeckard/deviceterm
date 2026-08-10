// SPDX-License-Identifier: GPL-3.0-or-later
//
/// `pane.subscribe` event `orientation.changed`. Broadcast on every
/// `pane.input.rotate` so a rotation from any source (the owning GUI's
/// own icon, `deviceterm rotate`, or a future auto-rotate) reaches every
/// subscriber. `orientation` is the device's new `Orientation`; the GUI
/// adopts it to re-render (counter-rotate the surface) and re-map input
/// instead of drifting from the device's true orientation.
public struct OrientationChangedEvent: Codable, Sendable, Equatable {
    public let paneId: String
    /// The device's new `Orientation` as its rawValue string, matching
    /// the `pane.input.rotate` wire convention (`RotateParams.orientation`
    /// is also a string the handler resolves via `Orientation(rawValue:)`).
    public let orientation: String

    public init(paneId: String, orientation: String) {
        self.paneId = paneId
        self.orientation = orientation
    }
}
