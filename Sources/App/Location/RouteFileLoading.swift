// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Reading a `.gpx` off the main actor.
///
/// The one place in the route path that touches the filesystem, split out
/// so `PaneLocationViewModel` can be driven with a fake and so the pure
/// halves (`GPXDocument`, `GPXRouteMapper`) never grow an I/O dependency.
///
/// The production reader is a plain non-isolated struct, so its `async`
/// method runs on the global executor rather than the main actor. That
/// matters: a route file lives wherever the user put it, which may be a
/// network-mounted home directory, and this is invoked from a menu.
///
/// **The GUI reads the file; the daemon never does.** What crosses the
/// wire is waypoints, so the daemon needs no GPX parser and inherits none
/// of the GUI's file access. Same split as Use My Location, where the GUI
/// resolves CoreLocation and the wire carries plain numbers.
protocol RouteFileLoading: Sendable {
    /// Read, parse, and validate the `.gpx` at `path`.
    func load(path: String) async throws -> SimulatedLocation
}
