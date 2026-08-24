// SPDX-License-Identifier: GPL-3.0-or-later

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
