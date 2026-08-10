// SPDX-License-Identifier: GPL-3.0-or-later
//
// RouteFileLoading: reading a `.gpx` off the main actor.
//
// The one place in the route path that touches the filesystem, split out
// so `PaneLocationViewModel` can be driven with a fake and so the pure
// halves (`GPXDocument`, `GPXRouteMapper`) never grow an I/O dependency.
//
// The production reader is a plain non-isolated struct, so its `async`
// method runs on the global executor rather than the main actor. That
// matters: a route file lives wherever the user put it, which may be a
// network-mounted home directory, and this is invoked from a menu.
//
// **The GUI reads the file; the daemon never does.** What crosses the
// wire is waypoints, so the daemon needs no GPX parser and inherits none
// of the GUI's file access. Same split as Use My Location, where the GUI
// resolves CoreLocation and the wire carries plain numbers.

import DaemonProtocol
import Foundation

/// Why a saved route can't be applied.
enum RouteFileError: Error, Equatable {
    /// The path named in the locations file couldn't be read.
    case unreadable(message: String)
    /// The bytes were read but aren't GPX this version understands.
    case malformed(GPXParseError)
    /// The file parsed into something no device will take: too many
    /// points, or a position off the globe. Carries the daemon's own
    /// vocabulary, so the alert says exactly what `pane.location.set`
    /// would have said. ("Too few" cannot arrive here: no points fails
    /// parsing as `noPoints`, and one becomes a coordinate.)
    case unusable(SimulatedLocationDefect)
}

protocol RouteFileLoading: Sendable {
    /// Read, parse, and validate the `.gpx` at `path`.
    func load(path: String) async throws -> SimulatedLocation
}

struct RouteFileReader: RouteFileLoading {
    // The `async` is load-bearing despite nothing being awaited inside.
    // A nonisolated `async` method runs on the global executor, so
    // declaring it this way is what moves the read and the parse off the
    // main actor; making it synchronous would run both on whichever
    // actor called it, which is always the one drawing the menu.
    // swiftlint:disable:next async_without_await
    func load(path: String) async throws -> SimulatedLocation {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw RouteFileError.unreadable(message: ErrorText.describing(error))
        }
        let document: GPXDocument
        do {
            document = try GPXDocument.parse(data)
        } catch let error as GPXParseError {
            throw RouteFileError.malformed(error)
        }
        let location = GPXRouteMapper.location(for: document)
        // Validated here rather than left to the daemon so the failure
        // arrives as a sentence about this file, next to the row the
        // user clicked, instead of as an RPC error a menu would only
        // log. The daemon still re-checks: it does not trust a client.
        if let defect = location.defect {
            throw RouteFileError.unusable(defect)
        }
        return location
    }
}
