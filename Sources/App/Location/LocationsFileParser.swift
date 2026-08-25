// SPDX-License-Identifier: GPL-3.0-or-later
//
// LocationsFileParser: the line format of `<config home>/deviceterm/locations`.
//
//     # a comment
//     37.7749,-122.4194 San Francisco
//     51.5072,-0.1276 London
//     64.1466,-21.9426
//     ~/routes/commute.gpx
//     ~/routes/marathon.gpx Boston Marathon
//     "~/my routes/sunday run.gpx" Sunday Long Run
//
// One entry per line, in one of two shapes: a coordinate pair, or a path
// to a `.gpx` route file. Either may be followed by an optional label
// that runs to the end of the line and may contain spaces.
//
// **A coordinate is tried first, and the path form requires the `.gpx`
// suffix.** Not every unreadable line is a path: that would take a line
// written by a *newer* version of deviceterm and render it in the menu
// as a broken route, which is exactly what the preserve-what-you-don't-
// understand rule exists to prevent. Requiring the extension keeps
// unknown lines unknown.
//
// A bare path ends at the first whitespace; a path containing spaces is
// double-quoted (`"~/my routes/sunday run.gpx" Sunday`), which macOS
// paths routinely need. Quoting rather than a heuristic, because a rule
// that guessed where the path stopped would read some lines the opposite
// way from how they were written.
//
// **Parsed without a locale, deliberately.** A config file has one
// meaning regardless of who opens it, so `.` is always the decimal point
// and `,` always the pair separator. `CoordinateInput` is the opposite:
// it reads what a person typed, in that person's locale. The two must
// not be collapsed into one code path.
//
// **Anything this file can't read is not an error.** Unrecognized
// lines are not entries and not failures; `LocationsFile` preserves
// them verbatim across writes.

import DaemonProtocol
import Foundation

enum LocationsFileParser {
    /// Decimal places used when deviceterm writes a coordinate.
    ///
    /// Six is about 11cm at the equator, far finer than anything a
    /// simulated position needs, and short enough to stay readable in a
    /// file people edit by hand. It also fixes the dedup key: two
    /// coordinates are "the same saved location" exactly when they
    /// render to the same token at this precision.
    static let decimals = 6

    /// Extension that marks a line as a route rather than a coordinate.
    static let routeExtension = ".gpx"

    /// Parse one line into an entry, or nil for a blank line, a comment,
    /// or anything else this version doesn't recognize.
    ///
    /// `directory` is the folder holding the locations file, used to
    /// resolve a relative route path. Coordinates ignore it.
    static func entry(from line: String, relativeTo directory: String) -> LocationEntry? {
        // Newlines as well as spaces: a CRLF file leaves a `\r` on every
        // line once `LocationsFile` splits on `\n`, and `.whitespaces`
        // alone would leave it glued to the last field: an invisible
        // character on the end of every label, and a bare pair that
        // doesn't parse at all.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        return coordinateEntry(from: trimmed) ?? routeEntry(from: trimmed, relativeTo: directory)
    }

    /// Resolve a path as written in the file into one that can be opened.
    ///
    /// `~` always expands. A relative path joins `directory`, so a line
    /// can say `routes/commute.gpx` and mean "next to this file",
    /// which is what makes a locations file portable between machines.
    static func resolve(path: String, relativeTo directory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else {
            return (expanded as NSString).standardizingPath
        }
        let joined = (directory as NSString).appendingPathComponent(expanded)
        return (joined as NSString).standardizingPath
    }

    /// A `<lat>,<lon> [label]` line, or nil if it isn't one.
    private static func coordinateEntry(from trimmed: String) -> LocationEntry? {
        // Split at the first comma, then take the longitude as the first
        // whitespace-delimited token of what follows; the rest is the
        // label. Doing it in that order rather than tokenizing the line
        // first means whitespace may surround the comma, so the
        // `37.7749, -122.4194` spelling the menu *displays* can be
        // pasted straight back into the file and still read.
        guard let comma = trimmed.firstIndex(of: ",") else { return nil }
        let latitudeText = trimmed[..<comma]
        let rest = trimmed[trimmed.index(after: comma)...]
            .drop(while: \.isWhitespace)
        let longitudeEnd = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
        let label = rest[longitudeEnd...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let latitude = coordinate(latitudeText, in: SimulatedLocation.latitudeRange),
            let longitude = coordinate(rest[..<longitudeEnd], in: SimulatedLocation.longitudeRange)
        else {
            return nil
        }
        return .coordinate(
            latitude: latitude,
            longitude: longitude,
            label: label.isEmpty ? nil : label
        )
    }

    /// A `<path>.gpx [label]` line, or nil if it isn't one.
    ///
    /// Two spellings, both unambiguous:
    ///
    ///     ~/routes/run.gpx Sunday Long Run
    ///     "~/my routes/sunday run.gpx" Sunday Long Run
    ///
    /// The bare form ends at the first whitespace; a path containing
    /// spaces is double-quoted. There is deliberately **no heuristic**
    /// splitting the two apart, because none of them can be right: a
    /// rule that ended the path at the first `.gpx` followed by
    /// whitespace reads `/routes/old.gpx exports/run.gpx Morning` as the
    /// file `/routes/old.gpx` labelled `exports/run.gpx Morning`, which
    /// is a defensible reading of a line whose author meant the other
    /// one. Where a line could mean two things, the format has to pick
    /// the spelling, not guess the intent.
    ///
    /// A `.gpx` inside a *directory* name is not special under either
    /// spelling, since only the path's own suffix is tested:
    /// `/gpx.gpx-backups/run.gpx` is the file, not the folder.
    private static func routeEntry(
        from trimmed: String,
        relativeTo directory: String
    ) -> LocationEntry? {
        let path: String
        let rest: Substring
        if trimmed.hasPrefix("\"") {
            let afterQuote = trimmed.index(after: trimmed.startIndex)
            // An unterminated quote is not a route. Left unrecognized so
            // `LocationsFile` preserves the line rather than guessing
            // where the author meant it to end.
            guard let closing = trimmed[afterQuote...].firstIndex(of: "\"") else { return nil }
            path = String(trimmed[afterQuote..<closing])
            rest = trimmed[trimmed.index(after: closing)...]
        } else {
            let end = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
            path = String(trimmed[..<end])
            rest = trimmed[end...]
        }
        // A bare `.gpx` names no file. Rejecting it, like anything
        // without the suffix, keeps the line unrecognized, which is what
        // preserves it across a write.
        guard path.count > routeExtension.count,
            path.lowercased().hasSuffix(routeExtension) else {
            return nil
        }
        let label = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return .route(
            path: resolve(path: path, relativeTo: directory),
            label: label.isEmpty ? nil : label
        )
    }

    /// Render an entry as the line deviceterm writes for it.
    ///
    /// A route renders with its **resolved** path, so a line originally
    /// written as `~/routes/run.gpx` would come back absolute. That
    /// never happens to a real file: deviceterm only ever appends
    /// coordinates, and an existing route line is preserved verbatim
    /// rather than re-rendered. This arm exists so the function is total.
    static func line(for entry: LocationEntry) -> String {
        switch entry {
        case let .coordinate(latitude, longitude, label):
            let pair = coordinateToken(latitude: latitude, longitude: longitude)
            guard let label, !label.isEmpty else { return pair }
            return "\(pair) \(label)"

        case let .route(path, label):
            // Paths containing whitespace are quoted. The grammar has
            // no escape syntax, so a path containing both whitespace and
            // `"` cannot round-trip. A whitespace-free bare path may
            // contain a non-leading quote; a leading quote is read as
            // the quoted form.
            let token = path.contains(where: \.isWhitespace) ? "\"\(path)\"" : path
            guard let label, !label.isEmpty else { return token }
            return "\(token) \(label)"
        }
    }

    /// The dedup key for an entry: its coordinates at the file's
    /// precision, ignoring the label.
    ///
    /// Labels are excluded on purpose. Saving a point you already have
    /// under a new name should not add a second row pointing at the same
    /// place; the file is a list of *locations*, and the existing line
    /// (with whatever the user called it) wins.
    ///
    /// A route keys on its resolved path under a prefix, so it can never
    /// collide with a coordinate token however a file happens to be
    /// named. deviceterm never appends a route, so this only ever
    /// appears on the *existing*-entry side of a comparison.
    static func dedupKey(for entry: LocationEntry) -> String {
        switch entry {
        case let .coordinate(latitude, longitude, _):
            return coordinateToken(latitude: latitude, longitude: longitude)

        case let .route(path, _):
            return "gpx:" + path
        }
    }

    /// The value this file would store for `value`: rounded to
    /// `decimals`, with negative zero normalized to zero.
    ///
    /// Every coordinate that can be *saved* is put through this on the
    /// way in, so the value the daemon records and the value the file
    /// keeps are the same `Double`. Without that, typing `37.77490001`
    /// would set one number and save a different one, and the menu's
    /// exact-equality match would leave the saved row unchecked while
    /// appending a second row for the claim.
    ///
    /// Defined as "parse what we would have written" rather than as
    /// rounding arithmetic, so it agrees with `coordinateToken` by
    /// construction instead of by two implementations happening to round
    /// ties the same way.
    ///
    /// The trailing `+ 0.0` collapses `-0.0` to `0.0`. The two are `==`
    /// in IEEE (so the menu already treats them as one place) but render
    /// as different tokens, which would otherwise let the same location
    /// occupy two rows that refuse to deduplicate.
    ///
    /// It has to come **after** the rounding, not before. Rounding is
    /// what *creates* most negative zeros here: a real position just
    /// south of the equator, `-0.0000001`, is not `-0.0` on the way in
    /// but formats to `-0.000000` and reads back as one. Normalizing
    /// first only catches a value that was already exactly `-0.0`, which
    /// is the rarest way to reach this at all.
    static func canonical(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let rounded = Double(String(format: "%.\(decimals)f", value)) ?? value
        return rounded + 0.0
    }

    private static func coordinateToken(latitude: Double, longitude: Double) -> String {
        String(
            format: "%.\(decimals)f,%.\(decimals)f",
            canonical(latitude),
            canonical(longitude)
        )
    }

    /// One half of a coordinate pair. POSIX-only (`Double`'s own
    /// parsing), range-checked, and finite, so a file carrying `inf`
    /// yields no entry rather than a position nothing can render.
    private static func coordinate(
        _ text: Substring,
        in range: ClosedRange<Double>
    ) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            value.isFinite,
            range.contains(value) else {
            return nil
        }
        return value
    }
}
