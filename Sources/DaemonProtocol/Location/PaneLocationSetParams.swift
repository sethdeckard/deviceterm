// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire shape for `pane.location.set`.
///
/// Applies a simulated GPS position to the pane's device. One method for
/// every value it can take (coordinate, scenario, route, cleared). See
/// `SimulatedLocation`.
public struct PaneLocationSetParams: Codable, Sendable, Equatable {
    public let paneId: String
    public let location: SimulatedLocation

    public init(paneId: String, location: SimulatedLocation) {
        self.paneId = paneId
        self.location = location
    }
}
