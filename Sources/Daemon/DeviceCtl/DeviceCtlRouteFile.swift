// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The `--route-file` document, in devicectl's own documented schema
/// rather than deviceterm's wire shape.
///
/// Kept as an explicit `Encodable` rather than re-encoding `RouteSpec`,
/// because the two disagree deliberately: devicectl flattens the mode
/// into a `"mode"` string plus a sibling field, while the wire type
/// makes the pairing unrepresentable. Writing the translation out is
/// what lets a test pin the tool's format.
struct DeviceCtlRouteFile: Encodable, Equatable {
    struct Waypoint: Encodable, Equatable {
        let latitude: Double
        let longitude: Double
    }

    let mode: String
    /// Present only in distance mode; devicectl requires the field that
    /// matches `mode` and ignores the other.
    let distance: Double?
    /// Present only in interval mode.
    let interval: Double?
    let speed: Double
    let waypoints: [Waypoint]

    init(_ spec: RouteSpec) {
        switch spec.mode {
        case let .distance(meters):
            mode = "distance"
            distance = meters
            interval = nil

        case let .interval(seconds):
            mode = "interval"
            distance = nil
            interval = seconds
        }
        speed = spec.speed
        waypoints = spec.waypoints.map {
            Waypoint(latitude: $0.latitude, longitude: $0.longitude)
        }
    }
}
