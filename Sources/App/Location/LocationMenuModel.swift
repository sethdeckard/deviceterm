// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The pure row model behind Device ▸ Location.
///
/// Holds the entire ordering/sectioning rule for the submenu with no
/// AppKit involved, so the shape is exhaustively unit-testable and the
/// two surfaces that show it (the main menu and the pane's right-click
/// menu) can't drift apart. `LocationMenuController` does nothing but
/// turn these rows into `NSMenuItem`s.
///
/// Empty sections are omitted rather than shown disabled, so callers
/// need no section-specific branching.
enum LocationMenuModel {
    /// Clears any simulation, so the device falls back to whatever it
    /// would report on its own.
    static let clearedTitle = "None"
    /// Snapshots the Mac's position through CoreLocation and applies it.
    static let useMyLocationTitle = "Use My Location"
    /// The user's own saved points and routes, read from the locations
    /// file. Called "Locations" rather than "Recent" because
    /// `LocationsFile` never evicts entries.
    static let savedHeader = "Locations"
    /// The built-in moving scenarios both backends vend (City Run,
    /// Freeway Drive, and so on). Named "Trips" to match Simulator.app.
    static let tripsHeader = "Trips"
    /// Opens the sheet for typing a position by hand.
    static let customTitle = "Custom Coordinates…"

    /// Build the submenu's rows for a pane's current location state.
    ///
    /// A `nil` claim checks no rows; a known claim checks exactly one.
    /// These rules produce that, and none of them depends on the device
    /// list being well formed:
    ///
    /// - Any claimed value not already represented by a row gets one
    ///   appended. Without it, a location this build of the menu doesn't
    ///   otherwise offer (a coordinate, say) would render with no
    ///   checkmark anywhere, reading as "nothing is set" while the daemon
    ///   still holds a location claim.
    /// - Only the *first* row matching the claim is marked active. A
    ///   scenario name is the identifier `pane.location.set` consumes, so
    ///   a device reporting the same name twice is already an anomaly;
    ///   this keeps it from becoming a second checkmark rather than
    ///   relying on the backends to guarantee uniqueness.
    /// - A `nil` claim checks nothing at all, rather than `None`. `nil`
    ///   means deviceterm has no claim (it never wrote, or the pane
    ///   transferred or reset), whereas `None` asserts the simulation was
    ///   cleared. Ownership transfer and teardown send no clear, so
    ///   `.cleared` cannot be inferred from them.
    ///
    /// `saved` preserves file order, which is also menu order because
    /// the user controls its arrangement.
    ///
    /// `activeRoutePath` is the route file the view model last applied
    /// and whose claim the daemon still holds. A route row can't be
    /// matched by value the way the others are: the claim carries
    /// waypoints and the row carries a path, and connecting them would
    /// mean opening the file while the menu is being drawn. So the
    /// checkmark follows the route deviceterm applied.
    static func rows(
        for state: PaneLocationStateResult,
        saved: [LocationEntry] = [],
        activeRoutePath: String? = nil
    ) -> [LocationMenuRow] {
        // Set once the claim has been matched, so a duplicate entry in
        // the device's list can't produce a second checkmark.
        var claimMatched = false
        func matches(_ location: SimulatedLocation) -> Bool {
            guard !claimMatched, state.location == location else { return false }
            claimMatched = true
            return true
        }
        // A route consumes the claim on the same terms, so a one-point
        // `.gpx` (which applies as a plain coordinate) can't check both
        // its own row and a saved point at the same position.
        func matchesRoute(_ path: String) -> Bool {
            guard !claimMatched, state.location != nil, path == activeRoutePath else {
                return false
            }
            claimMatched = true
            return true
        }

        // `None` and Use My Location are always offered and need no
        // section of their own: both act on the device directly rather
        // than picking from a list.
        var rows: [LocationMenuRow] = [
            .location(
                title: clearedTitle,
                location: .cleared,
                isActive: matches(.cleared)
            ),
            .useMyLocation
        ]

        // Nothing saved yet is the state a new install is in, so the
        // section is omitted rather than shown as an empty header.
        if !saved.isEmpty {
            rows.append(.separator)
            rows.append(.header(title: savedHeader))
            for entry in saved {
                switch entry {
                case let .coordinate(latitude, longitude, _):
                    let location = SimulatedLocation.coordinate(
                        latitude: latitude,
                        longitude: longitude
                    )
                    rows.append(
                        .location(
                            title: entry.label ?? title(for: location),
                            location: location,
                            isActive: matches(location)
                        )
                    )

                case let .route(path, _):
                    rows.append(
                        .route(
                            title: entry.label ?? routeTitle(forPath: path),
                            path: path,
                            isActive: matchesRoute(path)
                        )
                    )
                }
            }
        }

        // Empty means no scenarios are available: the device may be
        // stopped, or enumeration may have failed. Either way the section
        // doesn't appear.
        if !state.scenarios.isEmpty {
            rows.append(.separator)
            rows.append(.header(title: tripsHeader))
            for name in state.scenarios {
                rows.append(
                    .location(
                        title: name,
                        location: .scenario(name: name),
                        isActive: matches(.scenario(name: name))
                    )
                )
            }
        }

        if let claimed = state.location, !claimMatched {
            rows.append(.separator)
            rows.append(.location(title: title(for: claimed), location: claimed, isActive: true))
        }
        rows.append(.separator)
        rows.append(.customCoordinates)
        return rows
    }

    /// A coordinate rendered for display, e.g. `37.7749, -122.4194`.
    ///
    /// Deliberately not localized: `String(format:)` with no locale
    /// formats in the POSIX style, so the text always uses a fixed
    /// decimal point and the comma stays an unambiguous pair separator.
    /// A localized decimal comma would collide with it.
    static func formatCoordinate(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }

    /// What an unlabeled route row reads as: its file name without the
    /// extension.
    ///
    /// Deliberately **not** the first waypoint's `<name>`, which would
    /// be a nicer title and would cost opening every saved `.gpx` on
    /// every menu open, on the main actor. The user names a route by
    /// naming the file or by putting a label on its line.
    static func routeTitle(forPath path: String) -> String {
        let stem = ((path as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        return stem.isEmpty ? path : stem
    }

    /// The menu title for a location that has no row of its own.
    private static func title(for location: SimulatedLocation) -> String {
        switch location {
        case .cleared:
            return clearedTitle

        case let .coordinate(latitude, longitude):
            return formatCoordinate(latitude: latitude, longitude: longitude)

        case let .scenario(name):
            return name

        case let .route(spec):
            // Reached when the daemon claims a route the menu can't
            // attribute to a row: a route started before this GUI came
            // up, or a pane adopted from another session. Naming the
            // size is all that can honestly be said about it, and it is
            // still better than losing the checkmark.
            return "Route (\(spec.waypoints.count) waypoints)"
        }
    }
}
