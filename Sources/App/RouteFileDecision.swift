// SPDX-License-Identifier: GPL-3.0-or-later
//
// RouteFileDecision: what to tell the user when a `.gpx` row won't play.
//
// Pure and total over `RouteFileError`, following the same shape as
// `UseMyLocationDecision`: a new failure case stops compiling here
// rather than reaching the user as nothing happening.
//
// Every message names the file. A route row's title can be a label the
// user chose, so "that file is missing" is unhelpful unless it says
// which path the line pointed at, and the locations file is where they
// would go to fix it.

import Foundation

enum RouteFileDecision {
    /// The alert for a route that couldn't be loaded.
    static func alert(for error: RouteFileError, path: String) -> LocationAlert {
        switch error {
        case let .unreadable(message):
            return LocationAlert(
                title: "Couldn't open that route",
                body: "DeviceTerm couldn't read \(path). \(message)",
                settingsURL: nil
            )

        case let .malformed(parseError):
            return LocationAlert(
                title: "That route file couldn't be read",
                body: "\(path) is not GPX DeviceTerm understands. \(describe(parseError))",
                settingsURL: nil
            )

        case let .unusable(defect):
            return LocationAlert(
                title: "That route can't be played",
                body: "\(path) parsed, but \(defect.message).",
                settingsURL: nil
            )
        }
    }

    /// The alert for a route that loaded but the device refused.
    ///
    /// Stops at "starting it failed" rather than claiming the device is
    /// unchanged: a transport failure can land after the backend already
    /// began playback. Same reasoning as
    /// `UseMyLocationDecision.applyFailure`.
    static func startFailure(reason: String) -> LocationAlert {
        LocationAlert(
            title: "Couldn't start that route on this device",
            body: "DeviceTerm read the route, but starting it on the device "
                + "failed. \(reason)",
            settingsURL: nil
        )
    }

    /// A parse failure in the user's terms. `GPXParseError` names XML
    /// internals, which is the right vocabulary for a log and the wrong
    /// one for an alert.
    private static func describe(_ error: GPXParseError) -> String {
        switch error {
        case let .malformedXML(message):
            return "The XML wouldn't parse: \(message)"

        case .noPoints:
            return "It contains no waypoints, track points, or route points."

        case let .invalidPoint(element, index):
            return "Its \(element) number \(index + 1) has no usable lat/lon pair."

        case let .multipleSequences(element, count):
            // Actionable rather than descriptive, and in the file's
            // vocabulary rather than the parser's: the fix is to keep
            // one stretch or merge them, and neither is obvious from
            // "multiple sequences".
            let kind = element == "rtept" ? "route" : "track"
            return "Its \(kind) is broken into \(count) separate stretches, and "
                + "DeviceTerm plays one continuous route. A new <trk>, <trkseg>, or "
                + "<rte> starts a stretch. Keep the one you want, or merge them."
        }
    }
}
