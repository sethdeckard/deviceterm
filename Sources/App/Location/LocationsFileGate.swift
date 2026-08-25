// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import os

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
