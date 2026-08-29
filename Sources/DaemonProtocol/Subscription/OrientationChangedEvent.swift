// SPDX-License-Identifier: GPL-3.0-or-later

/// `pane.subscribe` event `orientation.changed`. Broadcast when the pane's
/// confirmed presentation orientation changes. The GUI adopts it to
/// counter-rotate the surface and re-map input.
public struct OrientationChangedEvent: Codable, Sendable, Equatable {
    public let paneId: String
    /// The confirmed `Orientation` as its raw-value string, matching the
    /// `pane.input.rotate` wire convention.
    public let orientation: String

    public init(paneId: String, orientation: String) {
        self.paneId = paneId
        self.orientation = orientation
    }
}
