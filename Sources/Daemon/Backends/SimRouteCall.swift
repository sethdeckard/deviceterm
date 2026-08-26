// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// A wire `RouteSpec` in the shape CoreSimulator's route
/// selectors want.
///
/// The simulator counterpart of `DeviceCtlRouteFile`, and it exists for
/// the same reason: the two representations disagree deliberately, and
/// writing the translation out is what lets a test pin it.
///
/// What it translates is the thing most able to be wrong without looking
/// wrong. `startLocationSimulationWith{Distance,Interval}:speed:waypoints:`
/// declares `waypoints` as a bare `NSArray`, takes a **flat list of
/// alternating latitude and longitude numbers** rather than points, and
/// returns a plain `BOOL` with no validation behind it. Swap the order of
/// each pair and the call still succeeds; the device simply walks
/// somewhere else. Nothing downstream can catch that, so the ordering
/// lives here, in a pure value a unit test can read back.
struct SimRouteCall: Equatable {
    /// Which of the two selectors to call, and its scalar. They are
    /// separate selectors, so this is a choice rather than a parameter.
    enum Cadence: Equatable {
        case distance(Double)
        case interval(Double)
    }

    let cadence: Cadence
    let speed: Double
    /// Flat and alternating: `[lat0, lon0, lat1, lon1, …]`. Four values
    /// are two waypoints. See `SimLocation.h` for how that shape was
    /// established.
    let waypoints: [NSNumber]

    init(_ spec: RouteSpec) {
        switch spec.mode {
        case let .distance(meters):
            cadence = .distance(meters)

        case let .interval(seconds):
            cadence = .interval(seconds)
        }
        speed = spec.speed
        waypoints = spec.waypoints.flatMap {
            [NSNumber(value: $0.latitude), NSNumber(value: $0.longitude)]
        }
    }
}
