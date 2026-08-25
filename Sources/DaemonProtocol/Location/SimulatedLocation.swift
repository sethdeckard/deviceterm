// SPDX-License-Identifier: GPL-3.0-or-later

/// A simulated GPS position for one pane's device: the *value* of a
/// single device property, not several separate operations. Coordinate,
/// scenario, route, and cleared are the things that property can be, so
/// `pane.location.set` takes one of these rather than splitting into
/// set/scenario/route/clear methods. The menu that drives it is a radio
/// group over this type.
///
/// A route is a value here for the same reason a scenario is: both play
/// over time, and the device is at exactly one of them. The difference
/// is only who supplies the waypoints, Apple's built-in trips or the
/// user's own `.gpx`.
///
/// `cleared` rather than `none` so the case never reads as
/// `Optional.none` at a call site. It matches both backends' vocabulary:
/// CoreSimulator's `clearSimulatedLocationWithError:` and
/// `devicectl device simulate location clear`.
///
/// No label travels on the wire. The GUI derives display text from the
/// location value, so the daemon stores no user-authored strings.
///
/// `Codable` via Swift's automatic external-tagging synthesis, matching
/// the `PaneTarget` / `PaneSlot` precedent:
///
///   - `.cleared`                         → `{"cleared":{}}`
///   - `.coordinate(latitude:longitude:)` → `{"coordinate":{"latitude":37.3,"longitude":-122}}`
///   - `.scenario(name:)`                 → `{"scenario":{"name":"City Run"}}`
///   - `.route(spec:)`                    → `{"route":{"spec":{…}}}`
///
/// A golden test pins those exact bytes so a future change to
/// the synthesis can't drift the wire silently. `route` carries a
/// *labelled* payload for that reason: an unlabelled one would encode
/// under Swift's synthesized `_0` key, putting a compiler-internal name
/// on the wire.
public enum SimulatedLocation: Equatable, Hashable, Sendable, Codable {
    case cleared
    case coordinate(latitude: Double, longitude: Double)
    case scenario(name: String)
    case route(spec: RouteSpec)

    /// Accepted latitude, in degrees.
    public static let latitudeRange: ClosedRange<Double> = -90...90
    /// Accepted longitude, in degrees.
    public static let longitudeRange: ClosedRange<Double> = -180...180

    /// Why this value can't be applied to a device, or `nil` when it is
    /// well-formed.
    ///
    /// Checked before the value reaches a backend so bad input surfaces
    /// as `invalidParams` rather than as an opaque bridge or subprocess
    /// error. `NaN` and the infinities fail the range tests (a
    /// `ClosedRange` contains neither), so they need no separate arm.
    ///
    /// A scenario *name* is checked here only for being empty. Whether
    /// it is one the device offers is a per-device runtime question, so
    /// that half is the backend's job, not this type's.
    public var defect: SimulatedLocationDefect? {
        switch self {
        case .cleared:
            return nil

        case let .coordinate(latitude, longitude):
            guard Self.latitudeRange.contains(latitude) else {
                return .latitudeOutOfRange(latitude)
            }
            guard Self.longitudeRange.contains(longitude) else {
                return .longitudeOutOfRange(longitude)
            }
            return nil

        case let .scenario(name):
            return name.isEmpty ? .emptyScenarioName : nil

        case let .route(spec):
            return spec.defect
        }
    }
}
