// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A request, dropped into the seat's requests directory, to capture what one
/// simulator pane draws for a while, bezel included, as PNGs in `out`. Each
/// drawn frame is attempted; one that can't be read back is skipped.
///
/// Written by `scripts/pane-snapshot.sh` as `<id>.json`; the app answers with
/// `<id>.done.json` beside it (`PaneSnapshotOutcome`).
struct PaneSnapshotRequest: Decodable, Equatable {
    /// The longest burst a request may ask for, in seconds. Each frame
    /// captured is written as a full-size PNG, so a long burst is a lot of
    /// disk.
    static let maximumSeconds: Double = 5

    /// The simulator whose pane to capture, as `deviceterm pane list` shows it.
    let udid: String
    /// How long to capture for.
    let seconds: Double
    /// The directory the frames go in, absolute. Created if missing.
    let out: String

    /// Why a request can't be run as written, or nil when it can.
    var problem: String? {
        if udid.isEmpty { return "udid is empty" }
        if !(seconds > 0 && seconds <= Self.maximumSeconds) {
            return "seconds must be more than 0 and at most \(Self.maximumSeconds)"
        }
        if !(out as NSString).isAbsolutePath { return "out must be an absolute path" }
        return nil
    }

    /// Whether the request names the simulator `udid`. UDIDs compare without
    /// regard to case: `simctl` prints them upper case, and a pane may hold
    /// one in lower.
    func names(udid other: String) -> Bool {
        udid.caseInsensitiveCompare(other) == .orderedSame
    }
}
