// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import os

/// A line-preserving reader/writer for
/// `<config home>/deviceterm/locations`.
///
/// Built on the same substrate as `ConfigFile`: the file is held as an
/// ordered list of raw lines, and a write appends without disturbing
/// anything already there. Comments and blank lines survive
/// byte-for-byte, and so do **lines this version does not understand**.
/// That last part is what forward compatibility depends on.
///
/// Unknown lines are preserved verbatim across appends, so entry kinds
/// this parser doesn't support remain intact. Such a line is never
/// parsed, warned about, or acted on, and never destroyed.
///
/// **A saved list, not a recents list.** deviceterm appends and nothing
/// else: it never reorders, never caps, never evicts. File order is menu
/// order, so the user is the one who curates it. Any MRU behavior would
/// eventually delete a line somebody typed by hand, which is not a thing
/// a file we advertise as hand-editable gets to do.
final class LocationsFile {
    static let defaultPath = XDGPaths.deviceTermLocations()

    /// Header written above the first entry when deviceterm creates the
    /// file, so a file that appeared on its own still explains itself.
    /// Only ever written to an empty file; never re-added.
    static let header = [
        "# deviceterm saved locations. Shown under Device ▸ Location.",
        "#",
        "# One per line: <latitude>,<longitude> [name]",
        "#   37.7749,-122.4194 San Francisco",
        "#",
        "# Or a path to a GPX file, to walk that route:",
        "#   ~/routes/commute.gpx Morning Commute",
        "# A route replays at one speed: the average of its <time>",
        "# stamps when every point has one, else 20 m/s.",
        "#",
        "# File order is menu order. deviceterm only ever appends here;",
        "# reorder or remove entries by editing this file."
    ]

    /// True when the file exists but could not be read.
    ///
    /// Distinguished from "no file yet" on purpose. A missing file is
    /// the ordinary state and means the user has saved nothing; a file
    /// that exists and won't open is a real failure that would otherwise
    /// present as an empty menu section forever, with nothing anywhere
    /// saying why. The store logs on this rather than degrading in
    /// silence.
    private(set) var isUnreadable = false

    /// Every entry the file defines, in file order. Unparseable lines
    /// are skipped here and preserved on write.
    ///
    /// A relative route path resolves against this file's own directory,
    /// which is the reason resolution happens here rather than in the
    /// parser's caller: this is the last place that knows where the file
    /// lives.
    var entries: [LocationEntry] {
        let directory = (path as NSString).deletingLastPathComponent
        return lines.compactMap { LocationsFileParser.entry(from: $0, relativeTo: directory) }
    }

    private let path: String
    private var lines: [String]

    init(path: String = LocationsFile.defaultPath) {
        self.path = path
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            // Match ConfigFile: keep the original split and don't
            // synthesize a trailing empty element for the final newline,
            // which `save()` re-adds.
            var split = text.components(separatedBy: "\n")
            if split.last?.isEmpty == true { split.removeLast() }
            lines = split
        } else {
            lines = []
            isUnreadable = FileManager.default.fileExists(atPath: path)
        }
    }

    /// Append `entry` unless the file already lists that position.
    ///
    /// Returns whether anything changed, so a caller can skip the write
    /// entirely on a duplicate. A duplicate leaves the existing line
    /// untouched rather than rewritten with the incoming one. That
    /// includes its label, which the user may have chosen.
    @discardableResult
    func append(_ entry: LocationEntry) -> Bool {
        let key = LocationsFileParser.dedupKey(for: entry)
        let isKnown = entries.contains { LocationsFileParser.dedupKey(for: $0) == key }
        guard !isKnown else { return false }
        if lines.isEmpty { lines = Self.header }
        lines.append(LocationsFileParser.line(for: entry))
        return true
    }

    /// Write back atomically, creating the parent directory if needed.
    ///
    /// Refuses outright when the file exists but wouldn't decode. In that
    /// state `lines` is empty not because the file is empty but because
    /// nothing could be read from it, so writing would replace a file
    /// full of the user's locations with a header and one entry. That is
    /// the exact opposite of this type's guarantee, and an atomic write
    /// makes it *reliably* destructive rather than occasionally so. A
    /// file saved in some other encoding, or one a stray byte corrupted,
    /// is the realistic way to get here.
    func save() throws {
        guard !isUnreadable else { throw LocationsFileError.unreadable(path: path) }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
