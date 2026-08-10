// SPDX-License-Identifier: GPL-3.0-or-later
//
// LocationsFile: a line-preserving reader/writer for
// `<config home>/deviceterm/locations`.
//
// Built on the same substrate as `ConfigFile`: the file is held as an
// ordered list of raw lines, and a write appends without disturbing
// anything already there. Comments and blank lines survive
// byte-for-byte, and so do **lines this version does not understand**.
// That last part is the load-bearing one.
//
// Unknown lines are preserved verbatim across appends, so entry kinds
// this parser doesn't support remain intact. Such a line is never
// parsed, warned about, or acted on, and never destroyed.
//
// **A saved list, not a recents list.** deviceterm appends and nothing
// else: it never reorders, never caps, never evicts. File order is menu
// order, so the user is the one who curates it. Any MRU behavior would
// eventually delete a line somebody typed by hand, which is not a thing
// a file we advertise as hand-editable gets to do.

import DaemonProtocol
import Foundation
import os

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

enum LocationsFileError: Error, Equatable {
    /// The file exists but couldn't be decoded, so its contents are
    /// unknown and must not be replaced.
    case unreadable(path: String)
}

/// The saved-locations file as its one consumer uses it, so
/// `PaneLocationViewModel` can be tested without touching a real path.
///
/// `record` answers nothing. The caller re-reads through `load()`
/// instead, because that is the view model's single fenced publication
/// path; handing back a list here would invite a second one, and two
/// publishers can resume out of order and revert the menu to a snapshot
/// older than the file.
protocol LocationsStoring: Sendable {
    /// Every saved location, in file order. Empty when nothing is saved
    /// *or* when the file can't be read. The menu has to render either
    /// way, so the distinction is logged rather than thrown.
    func load() async -> [LocationEntry]
    /// Save a location the user just applied, if it isn't already listed.
    func record(_ entry: LocationEntry) async
}

/// Serializes every read-modify-write of the locations file.
///
/// Saving is read, modify, write-the-whole-file. Run two of those
/// concurrently and both read the same original, then the second write
/// erases the first entry: the atomic replace guarantees no *partial*
/// file, and nothing at all about lost updates. Two panes saving at once
/// is enough to lose one, and it would look exactly like a save that
/// never happened.
///
/// Shared rather than per-store because the *file* is what needs
/// serializing, and each pane's view model holds its own store. Actor
/// rather than a lock, per the house rule for new shared mutable state;
/// the state being guarded is on disk rather than in memory, but the
/// need is the same.
actor LocationsFileGate {
    static let shared = LocationsFileGate()

    /// Subsystem is the app's bundle identifier, matching the daemon's
    /// `com.deviceterm.daemon`. These failures are only ever logged, so
    /// a subsystem nobody filters on would hide them completely.
    private let log = Logger(subsystem: "com.deviceterm", category: "locations-file")

    func load(path: String) -> [LocationEntry] {
        let file = LocationsFile(path: path)
        if file.isUnreadable {
            log.error("couldn't read saved locations at \(path, privacy: .public)")
        }
        return file.entries
    }

    func record(_ entry: LocationEntry, path: String) {
        let file = LocationsFile(path: path)
        guard file.append(entry) else { return }
        do {
            try file.save()
        } catch {
            // Includes the deliberate refusal to overwrite a file that
            // exists but wouldn't decode. Logged rather than surfaced:
            // the caller proceeds with the independent location-set
            // attempt after this returns, and this layer has no useful
            // recovery action to request mid-menu.
            log.error(
                """
                couldn't save location to \(path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }
}

/// Reads and writes the real file, opening it fresh on each call.
///
/// Statelessness is the point: a hand-edit is picked up with no cache to
/// invalidate, and several panes sharing one store can't disagree about
/// what the file says. Ordering comes from the shared gate, not from
/// holding state here.
///
/// Picked up is not the same as displayed. The menu draws from the view
/// model's snapshot and starts its read afterwards, so an edit made just
/// before an open shows up on the following one. See
/// `PaneLocationViewModel.savedLocations`.
struct LocationsFileStore: LocationsStoring {
    var path: String = LocationsFile.defaultPath

    func load() async -> [LocationEntry] {
        await LocationsFileGate.shared.load(path: path)
    }

    func record(_ entry: LocationEntry) async {
        await LocationsFileGate.shared.record(entry, path: path)
    }
}
