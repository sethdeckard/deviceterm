// SPDX-License-Identifier: GPL-3.0-or-later
//
// GPXDocument: the subset of GPX deviceterm reads.
//
// Pure: bytes in, points out, no filesystem and no route arithmetic.
// Turning these points into something a device can walk is
// `GPXRouteMapper`'s job, so the file format and the playback model stay
// separately testable.
//
// **Three point elements, in one order of precedence.** GPX spells a
// position three ways: `<trkpt>` inside a track, `<rtept>` inside a
// route, and a standalone `<wpt>`. Xcode's own GPX support reads only
// `<wpt>`, which is what its location templates emit, but virtually
// every exported route (a watch, a mapping site, a race organizer)
// records the path as a track. Reading only one of them would reject
// most real files or, worse, read a track file's handful of
// point-of-interest `<wpt>`s as though they were the route.
//
// So all three are collected and the most specific present one wins:
// track, then route, then standalone. A file with both a track and some
// `<wpt>` landmarks yields the track, which is the path the user drew.
//
// **One continuous run of points per file.** GPX marks a break in the
// path with a container boundary: a second `<trk>` or `<rte>` for a
// separate outing, a second `<trkseg>` for a gap in one recording.
// Neither backend can represent a discontinuity, and joining across one
// invents a leg from the end of the run to the start of the next: the
// device walks a straight line over ground nobody covered, and that
// fabricated distance goes into the derived average pace as well.
//
// So any file whose points fall into more than one run **fails**, rather
// than being silently spliced or silently truncated to whichever came
// first. That includes `<trkseg>`, and deliberately does not try to
// judge which breaks are small enough to bridge: a threshold would be
// the same kind of guess the route-line grammar refuses to make, and
// wrong in the same way, quietly and only for some people's files.
//
// **A malformed point fails the file.** A `<trkpt>` missing `lat`, or
// carrying something that isn't a number, is not skipped: silently
// dropping it would quietly reroute the journey around the bad point and
// still look like a success.

import Foundation

struct GPXDocument: Equatable, Sendable {
    /// The file's points, in the order they will be walked.
    var points: [GPXWaypoint]

    /// Whether every point carries a timestamp. Pace can only be derived
    /// from a fully-timed file; a partly-timed one has no defensible
    /// average.
    var isFullyTimed: Bool {
        !points.isEmpty && points.allSatisfy { $0.time != nil }
    }

    /// Points are returned in file order, except that a **fully timed**
    /// file is sorted ascending by time. That is Xcode's rule, and it is
    /// safe only when every point has a stamp: sorting a partly-timed
    /// list would interleave timed and untimed points arbitrarily, so
    /// such a file keeps the order its author wrote.
    static func parse(_ data: Data) throws -> GPXDocument {
        let collector = GPXCollector()
        let parser = XMLParser(data: data)
        // On, because it defaults off and every element name below is a
        // *local* name. A GPX file is free to bind its namespace to a
        // prefix, and a fair number do: without this, `<gpx:trkpt>`
        // arrives as the literal string `"gpx:trkpt"`, matches nothing,
        // and a perfectly good file reports `noPoints`.
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        guard parser.parse() else {
            if let failure = collector.failure { throw failure }
            let message = parser.parserError.map { "\($0)" } ?? "unreadable XML"
            throw GPXParseError.malformedXML(message)
        }
        if let failure = collector.failure { throw failure }

        // Track beats route beats standalone, and each is checked for
        // being one continuous run rather than several: see the file
        // comment. Empty runs are ignored rather than counted, so an
        // exporter's stub `<trk></trk>` beside a real one, or the outer
        // `<trk>` wrapping a single `<trkseg>`, is not a second run.
        let points = try single(collector.trackSequences, element: "trkpt")
            ?? single(collector.routeSequences, element: "rtept")
            ?? collector.standalonePoints
        guard !points.isEmpty else { throw GPXParseError.noPoints }

        var document = GPXDocument(points: points)
        if document.isFullyTimed {
            // The fallback is unreachable under `isFullyTimed`, which is
            // exactly the condition that every point has a time. It is
            // there so the comparison needs no force unwrap.
            document.points.sort { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
        }
        return document
    }

    /// The one non-empty run of this point kind, nil when there are
    /// none, or a failure when the points fall into more than one.
    private static func single(
        _ sequences: [[GPXWaypoint]],
        element: String
    ) throws -> [GPXWaypoint]? {
        let populated = sequences.filter { !$0.isEmpty }
        guard !populated.isEmpty else { return nil }
        guard populated.count == 1 else {
            throw GPXParseError.multipleSequences(element: element, count: populated.count)
        }
        return populated[0]
    }
}

private extension GPXDocument {
    /// Accumulates points while `XMLParser` walks the document.
    ///
    /// A class because `XMLParserDelegate` is a class protocol, and
    /// deliberately not `Sendable`: it is created, driven, and read inside
    /// one synchronous `parse(_:)` call and never crosses an isolation
    /// boundary.
    final class GPXCollector: NSObject, XMLParserDelegate {
        /// The GPX element names that carry a position, mapped to the bucket
        /// each fills.
        private enum PointKind: String {
            case trackPoint = "trkpt"
            case routePoint = "rtept"
            case standalone = "wpt"
        }

        /// The namespaces whose elements are GPX's own.
        ///
        /// Namespace processing reports a *local* name, which is what makes
        /// a prefixed `<gpx:trkpt>` readable, and equally makes a vendor's
        /// `<v:trkpt>` inside `<extensions>` look identical to the real
        /// thing. Both revisions are listed because 1.0 files are still
        /// exported.
        private static let gpxNamespaces: Set<String> = [
            "http://www.topografix.com/GPX/1/1",
            "http://www.topografix.com/GPX/1/0"
        ]

        /// One entry per `<trk>` *and* per `<trkseg>`, so every break in the
        /// recorded path stays visible to the caller, which refuses to
        /// splice across one. Empty entries (the outer `<trk>` around a
        /// single `<trkseg>`, an exporter's stub) are dropped by the caller
        /// rather than counted. See the file comment.
        private(set) var trackSequences: [[GPXWaypoint]] = []
        /// One entry per `<rte>`, same rule.
        private(set) var routeSequences: [[GPXWaypoint]] = []
        /// `<wpt>` has no container, so there is no sequence to track.
        private(set) var standalonePoints: [GPXWaypoint] = []
        /// Set when a point is structurally wrong. `XMLParser` has no way to
        /// fail from a delegate callback other than `abortParsing()`, which
        /// reports its own generic error, so the real reason is stashed here
        /// and rethrown by the caller.
        private(set) var failure: GPXParseError?

        private var pending: GPXWaypoint?
        private var pendingKind: PointKind?
        /// Text of the child element currently open inside a point, or nil
        /// when nothing is being captured. Also the reason `<name>` outside a
        /// point (a track's or the document's own name) is ignored.
        private var capturing: String?
        private var captured = ""

        /// ISO8601 both ways round. GPX's own schema says `xsd:dateTime`, and
        /// Xcode documents whole seconds, but exporters emit fractional
        /// seconds constantly. Accepting both costs one extra formatter and
        /// avoids rejecting a file over a `.000`.
        ///
        /// Per-instance rather than shared: `ISO8601DateFormatter` is not
        /// `Sendable`, and one collector lives for exactly one `parse(_:)`
        /// call, so a pair of allocations per file buys the isolation
        /// outright.
        private let timeFormatters: [ISO8601DateFormatter] = {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return [plain, fractional]
        }()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            guard isGPX(namespaceURI) else { return }
            // Every container boundary opens a new run, `<trkseg>` included:
            // that is precisely where GPX records a break in the path. A
            // point that turns up outside any container (malformed, but
            // cheap to tolerate) lands in an implicit run opened by `append`.
            if elementName == "trk" || elementName == "trkseg" { trackSequences.append([]) }
            if elementName == "rte" { routeSequences.append([]) }
            if let kind = PointKind(rawValue: elementName) {
                guard let latitude = attributes["lat"].flatMap(Double.init),
                    let longitude = attributes["lon"].flatMap(Double.init),
                    latitude.isFinite, longitude.isFinite else {
                    fail(.invalidPoint(element: elementName, index: count(of: kind)), on: parser)
                    return
                }
                pending = GPXWaypoint(latitude: latitude, longitude: longitude)
                pendingKind = kind
                return
            }
            guard pending != nil, elementName == "name" || elementName == "time" else { return }
            capturing = elementName
            captured = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capturing != nil else { return }
            captured += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            guard isGPX(namespaceURI) else { return }
            if let capturing, capturing == elementName {
                let text = captured.trimmingCharacters(in: .whitespacesAndNewlines)
                if capturing == "name" {
                    pending?.name = text.isEmpty ? nil : text
                } else {
                    pending?.time = date(from: text)
                }
                self.capturing = nil
                captured = ""
                return
            }
            guard let kind = PointKind(rawValue: elementName), let point = pending, kind == pendingKind
            else {
                return
            }
            switch kind {
            case .trackPoint:
                append(point, to: &trackSequences)

            case .routePoint:
                append(point, to: &routeSequences)

            case .standalone:
                standalonePoints.append(point)
            }
            pending = nil
            pendingKind = nil
        }

        /// Whether an element belongs to GPX rather than to a vendor
        /// extension.
        ///
        /// **Load-bearing once namespace processing is on.** With it, every
        /// vocabulary reports a bare local name, so `<v:trkpt>` inside
        /// `<extensions>` is indistinguishable from a real track point by
        /// name alone. A vendor point carrying `lat`/`lon` would be walked
        /// as part of the route; one without would be read as a malformed
        /// point and **fail the whole file**, which is the worse of the two.
        /// A vendor `<name>` or `<time>` would overwrite the real point's.
        ///
        /// An empty or absent URI is accepted: `XMLParser` reports `""` for
        /// a document that declares no namespace at all, and hand-written
        /// and older GPX files routinely don't.
        private func isGPX(_ namespaceURI: String?) -> Bool {
            guard let namespaceURI, !namespaceURI.isEmpty else { return true }
            return Self.gpxNamespaces.contains(namespaceURI)
        }

        /// Add to the open sequence, starting one if the file put a point
        /// outside its container.
        private func append(_ point: GPXWaypoint, to sequences: inout [[GPXWaypoint]]) {
            if sequences.isEmpty { sequences.append([]) }
            sequences[sequences.count - 1].append(point)
        }

        /// A malformed-XML failure from the parser itself, kept only when a
        /// structural one hasn't already been recorded: the abort below
        /// triggers this callback, and the reason we aborted is the more
        /// useful of the two.
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            guard failure == nil else { return }
            failure = .malformedXML("\(parseError)")
        }

        private func count(of kind: PointKind) -> Int {
            switch kind {
            case .trackPoint:
                return trackSequences.reduce(0) { $0 + $1.count }

            case .routePoint:
                return routeSequences.reduce(0) { $0 + $1.count }

            case .standalone:
                return standalonePoints.count
            }
        }

        private func fail(_ error: GPXParseError, on parser: XMLParser) {
            failure = error
            parser.abortParsing()
        }

        private func date(from text: String) -> Date? {
            guard !text.isEmpty else { return nil }
            for formatter in timeFormatters {
                if let date = formatter.date(from: text) { return date }
            }
            return nil
        }
    }
}
