// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// GPXDocumentTests: what a real `.gpx` says.
//
// Fixtures rather than string literals, per the house rule, and the
// awkward ones are the point: a track sharing a file with landmark
// `<wpt>`s, a partly-timed track, a point with no `lat`.
//
// The rule these mostly defend is that a malformed point **fails the
// file**. Skipping it would silently shorten the decoded journey and
// reroute it around the bad point, while still reporting success.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "gpx"),
        "missing fixture \(name).gpx"
    )
    return try Data(contentsOf: url)
}

private func parse(_ name: String) throws -> GPXDocument {
    try GPXDocument.parse(fixture(name))
}

// MARK: - Point elements

@Test("a single wpt parses with its name")
func parsesSingleWaypoint() throws {
    let document = try parse("gpx-single-wpt")
    #expect(document.points.count == 1)
    #expect(document.points.first?.latitude == 37.7749)
    #expect(document.points.first?.longitude == -122.4194)
    #expect(document.points.first?.name == "San Francisco")
}

@Test("a track parses in file order")
func parsesTrack() throws {
    let document = try parse("gpx-track-untimed")
    #expect(document.points.map(\.longitude) == [0.0, 0.001, 0.002])
    #expect(!document.isFullyTimed)
}

/// The precedence rule, and the reason it exists. A route file exported
/// from a mapping tool routinely carries landmark `<wpt>`s beside the
/// track; reading those would replay a couple of points of interest
/// instead of the journey.
@Test("a track wins over standalone waypoints in the same file")
func trackBeatsStandaloneWaypoints() throws {
    let document = try parse("gpx-track-and-waypoints")
    #expect(document.points.map(\.latitude) == [1.0, 2.0])
}

/// Route points sit between the two: more specific than a loose `<wpt>`,
/// less so than a recorded track.
@Test("route points win over standalone waypoints")
func routePointsBeatStandaloneWaypoints() throws {
    let document = try parse("gpx-rtept")
    #expect(document.points.map(\.latitude) == [3.0, 4.0])
    #expect(document.points.first?.name == "Start")
}

// MARK: - Sequence boundaries

/// Two `<trk>` elements are two outings. Joining them fabricates a leg
/// from the end of one to the start of the other, which the device then
/// walks in a straight line and whose distance also inflates the derived
/// pace.
@Test("several tracks are refused rather than spliced")
func severalTracksAreRefused() throws {
    #expect(throws: GPXParseError.multipleSequences(element: "trkpt", count: 2)) {
        try parse("gpx-two-tracks")
    }
}

@Test("several routes are refused rather than spliced")
func severalRoutesAreRefused() throws {
    #expect(throws: GPXParseError.multipleSequences(element: "rtept", count: 2)) {
        try parse("gpx-two-routes")
    }
}

/// A `<trkseg>` break is where GPX records a gap in one recording, and
/// it is refused on the same terms as a second `<trk>`. Bridging it
/// would be a judgement about which gaps are small enough to walk
/// across, and no threshold can make that call for someone else's file:
/// a few seconds of lost reception and an hour's lunch break look
/// identical to the parser.
@Test("several segments are refused, like several tracks")
func severalSegmentsAreRefused() throws {
    #expect(throws: GPXParseError.multipleSequences(element: "trkpt", count: 2)) {
        try parse("gpx-track-two-segments")
    }
}

/// The ordinary shape must still parse: one `<trk>` wrapping one
/// `<trkseg>` opens two runs, and the outer one is empty.
@Test("a single track with a single segment is one run")
func singleSegmentIsOneRun() throws {
    #expect(try parse("gpx-track-untimed").points.count == 3)
}

/// Counted by content, not by tag, so an exporter's empty `<trk>` stub
/// beside a real one isn't reported as two journeys.
@Test("an empty track beside a real one is not a second journey")
func emptyTrackIsNotCounted() throws {
    let document = try parse("gpx-empty-track-beside-real")
    #expect(document.points.map(\.latitude) == [7.0, 7.0])
}

// MARK: - Namespaces

/// GPX files bind their namespace, and some bind it to a *prefix*.
/// `XMLParser` reports prefixed elements verbatim unless namespace
/// processing is on, so `<gpx:trkpt>` would arrive as the literal
/// `"gpx:trkpt"`, match nothing, and report a good file as having no
/// points at all.
@Test("a prefixed namespace still parses")
func prefixedNamespaceParses() throws {
    let document = try parse("gpx-prefixed-namespace")
    #expect(document.points.map(\.latitude) == [1.0, 3.0])
    // Child elements resolve by local name too, not just the points.
    #expect(document.points.first?.name == "Start")
}

/// The common shape, and the one that would keep working either way:
/// a default namespace leaves element names unprefixed. Pinned so
/// turning namespace processing on can't regress it, and carrying a
/// second `xmlns:` (Garmin's track-point extensions) because real
/// exports do.
@Test("a default namespace still parses")
func defaultNamespaceParses() throws {
    let document = try parse("gpx-default-namespace")
    #expect(document.points.map(\.latitude) == [5.0, 7.0])
    #expect(document.isFullyTimed)
}

/// Namespace processing reports a bare local name for *every*
/// vocabulary, so a vendor's `<v:trkpt>` inside `<extensions>` looks
/// exactly like a real track point. This one carries no `lat`/`lon`, so
/// reading it would fail the whole file, and its `<v:name>` / `<v:time>`
/// would overwrite the real point's.
@Test("a vendor extension is not mistaken for GPX")
func vendorExtensionIsIgnored() throws {
    let document = try parse("gpx-vendor-extension-collision")
    #expect(document.points.map(\.latitude) == [1.0, 3.0])
    #expect(document.points.first?.name == "Real")
    #expect(document.points.first?.time == Date(timeIntervalSince1970: 1_767_225_600))
}

/// The other half: a vendor point that *does* carry coordinates would
/// be walked as part of the route, silently adding a leg to somewhere
/// the file never described.
@Test("a vendor point with coordinates is not walked")
func vendorPointWithCoordinatesIsIgnored() throws {
    let document = try parse("gpx-vendor-extension-waypoint")
    #expect(document.points.map(\.latitude) == [1.0, 3.0])
}

/// GPX 1.0 binds a different namespace and is still exported, so the
/// filter has to admit both revisions rather than only the current one.
@Test("a GPX 1.0 namespace is accepted")
func gpx10NamespaceIsAccepted() throws {
    let document = try parse("gpx-gpx10-namespace")
    #expect(document.points.map(\.latitude) == [9.0, 11.0])
    #expect(document.points.first?.name == "Old Schema")
}

/// Both delegate callbacks filter, not just the opening one.
///
/// The schema puts `<extensions>` last inside a point, which is why the
/// other fixtures never exercise the closing half; exporters do not all
/// respect that order. Here a vendor point closes *before* the real
/// `<name>` arrives. Unfiltered, that close is read as the end of the
/// enclosing `<trkpt>`: the point is committed early, and the name that
/// follows lands on nothing.
@Test("a vendor element closing early does not commit the point")
func vendorCloseDoesNotCommitThePoint() throws {
    let document = try parse("gpx-vendor-extension-first")
    #expect(document.points.map(\.latitude) == [1.0, 3.0])
    #expect(document.points.first?.name == "Real")
}

/// A `<name>` outside a point (a track's, or the document's own) must
/// not be captured as a point's name.
@Test("a track's own name is not a point's name")
func trackNameIsNotAPointName() throws {
    let document = try parse("gpx-track-timed")
    #expect(document.points.allSatisfy { $0.name == nil })
}

// MARK: - Time

@Test("a fully timed track reports so and keeps its order")
func fullyTimedTrack() throws {
    let document = try parse("gpx-track-timed")
    #expect(document.isFullyTimed)
    #expect(document.points.map(\.longitude) == [0.0, 0.001, 0.002])
}

/// Xcode's rule, applied only where it is safe. Fractional seconds are
/// accepted too: the fixture carries `.500`, which exporters emit
/// constantly and Xcode itself rejects.
@Test("a fully timed track is sorted by time")
func timedTrackIsSorted() throws {
    let document = try parse("gpx-track-out-of-order")
    #expect(document.isFullyTimed)
    #expect(document.points.map(\.longitude) == [0.0, 0.001, 0.002])
}

/// Sorting a partly-timed list would interleave stamped and unstamped
/// points arbitrarily, so such a file keeps the order its author wrote.
@Test("a partly timed track keeps file order")
func partlyTimedTrackKeepsFileOrder() throws {
    let document = try parse("gpx-track-partly-timed")
    #expect(!document.isFullyTimed)
    #expect(document.points.map(\.longitude) == [0.002, 0.0, 0.001])
}

// MARK: - Failures

@Test("a point with no lat fails the file")
func missingLatitudeFailsTheFile() throws {
    #expect(throws: GPXParseError.invalidPoint(element: "trkpt", index: 1)) {
        try parse("gpx-missing-lat")
    }
}

@Test("a file with no points is rejected")
func noPointsIsRejected() throws {
    #expect(throws: GPXParseError.noPoints) {
        try parse("gpx-no-points")
    }
}

@Test("unparseable XML is rejected")
func malformedXMLIsRejected() throws {
    let error = try #require(rejects("gpx-malformed"))
    guard case .malformedXML = error else {
        Issue.record("expected malformedXML, got \(error)")
        return
    }
}

/// Not this type's job. A latitude of 91 is well-formed GPX; whether a
/// device will take it is `RouteSpec.defect`'s question, asked once, in
/// the vocabulary the daemon uses.
@Test("an off-globe point parses, and is rejected later")
func offGlobePointParses() throws {
    let document = try parse("gpx-off-globe")
    #expect(document.points.count == 2)
    #expect(GPXRouteMapper.location(for: document).defect != nil)
}

private func rejects(_ name: String) -> GPXParseError? {
    do {
        _ = try parse(name)
        return nil
    } catch let error as GPXParseError {
        return error
    } catch {
        return nil
    }
}
