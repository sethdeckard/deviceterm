// SPDX-License-Identifier: GPL-3.0-or-later

/// `pane.subscribe` event `orientation.changed`. Broadcast when the pane's
/// confirmed presentation orientation, or a foldable's device orientation,
/// changes. The GUI adopts it to counter-rotate the surface and re-map input.
public struct OrientationChangedEvent: Codable, Sendable, Equatable {
    public let paneId: String
    /// The confirmed `Orientation` as its raw-value string, matching the
    /// `pane.input.rotate` wire convention.
    public let orientation: String
    /// A foldable's physical orientation, as an `Orientation` raw value: the
    /// way the device itself is turned, whatever its interface shows. A
    /// foldable's pane is drawn in it. Absent until the daemon has observed or
    /// commanded an orientation, and for every other device. Optional so
    /// events from peers that omit it still decode.
    public let deviceOrientation: String?

    public init(paneId: String, orientation: String, deviceOrientation: String? = nil) {
        self.paneId = paneId
        self.orientation = orientation
        self.deviceOrientation = deviceOrientation
    }
}
