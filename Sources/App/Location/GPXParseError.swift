// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum GPXParseError: Error, Equatable {
    /// The bytes aren't well-formed XML, or the parser gave up.
    case malformedXML(String)
    /// Well-formed XML with no `<trkpt>`, `<rtept>`, or `<wpt>` in it.
    /// Usually means the file isn't GPX at all.
    case noPoints
    /// A point element without a usable `lat`/`lon` pair. Carries the
    /// element name and its ordinal within that element kind, since a
    /// long file gives the reader nothing else to go on.
    case invalidPoint(element: String, index: Int)
    /// The points fall into more than one run, separated by a `<trk>`,
    /// `<trkseg>`, or `<rte>` boundary. deviceterm plays one continuous
    /// route, and bridging a break would fabricate a leg across it.
    /// `element` is the point element involved (`trkpt` or `rtept`).
    case multipleSequences(element: String, count: Int)
}
