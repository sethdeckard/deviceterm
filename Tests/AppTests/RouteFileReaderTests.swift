// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

// RouteFileReaderTests: read, parse, map, validate, in one pass.
//
// The pure halves are covered separately (`GPXDocumentTests`,
// `GPXRouteMapperTests`); they are only useful wired together, and the
// wiring is where a failure can turn into a success. In particular,
// validating **here** rather than leaving it to the daemon is what makes
// a bad file report a sentence about the file next to the row the user
// clicked, instead of an RPC error a menu would only log.

private func fixturePath(_ name: String) throws -> String {
    try #require(
        Bundle.module.url(forResource: name, withExtension: "gpx"),
        "missing fixture \(name).gpx"
    ).path
}

@Test("a track file loads as a route")
func readerLoadsATrack() async throws {
    let location = try await RouteFileReader().load(path: try fixturePath("gpx-track-untimed"))
    guard case let .route(spec) = location else {
        Issue.record("expected a route, got \(location)")
        return
    }
    #expect(spec.waypoints.count == 3)
    #expect(spec.speed == RouteSpec.defaultSpeed)
}

@Test("a one-point file loads as a coordinate")
func readerLoadsASinglePoint() async throws {
    let location = try await RouteFileReader().load(path: try fixturePath("gpx-single-wpt"))
    #expect(location == .coordinate(latitude: 37.7749, longitude: -122.4194))
}

/// The ordinary way a saved route goes wrong: the file moved or was
/// renamed after the line was written.
@Test("a missing file reports unreadable")
func readerReportsAMissingFile() async {
    await #expect(throws: RouteFileError.self) {
        _ = try await RouteFileReader().load(path: "/nonexistent/route.gpx")
    }
    let error = await failure(of: "/nonexistent/route.gpx")
    guard case .unreadable = error else {
        Issue.record("expected unreadable, got \(String(describing: error))")
        return
    }
}

@Test("unparseable bytes report malformed")
func readerReportsMalformedXML() async throws {
    let error = await failure(of: try fixturePath("gpx-malformed"))
    guard case .malformed = error else {
        Issue.record("expected malformed, got \(String(describing: error))")
        return
    }
}

/// The load-bearing wiring. The file parses cleanly as XML and produces
/// a route the *daemon* would reject, so validating in the reader is
/// what turns an RPC failure into a sentence about this file.
@Test("a file that parses but won't play reports the daemon's own reason")
func readerReportsAnUnusableRoute() async throws {
    let error = await failure(of: try fixturePath("gpx-off-globe"))
    guard case let .unusable(defect) = error else {
        Issue.record("expected unusable, got \(String(describing: error))")
        return
    }
    #expect(defect == .routeWaypointOutOfRange(index: 1, latitude: 91, longitude: 0.001))
}

@Test("a file with no points reports malformed, naming the reason")
func readerReportsNoPoints() async throws {
    let error = await failure(of: try fixturePath("gpx-no-points"))
    #expect(error == .malformed(.noPoints))
}

private func failure(of path: String) async -> RouteFileError? {
    do {
        _ = try await RouteFileReader().load(path: path)
        return nil
    } catch let error as RouteFileError {
        return error
    } catch {
        return nil
    }
}
