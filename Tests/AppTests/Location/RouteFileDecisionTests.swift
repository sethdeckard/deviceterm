// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

// RouteFileDecisionTests: every route failure says something, and says
// which file.
//
// A route row's title can be a label the user chose ("Boston Marathon"),
// so an alert that only says "that file is missing" leaves them with
// nowhere to go. The path is the thing they would edit.
//
// The mapping is total over `RouteFileError` by construction, which is
// the property that keeps a future failure case from reaching the user
// as nothing happening.

private let path = "/routes/marathon.gpx"

@Test("every failure names the file", arguments: [
    RouteFileError.unreadable(message: "No such file or directory"),
    .malformed(.noPoints),
    .malformed(.malformedXML("line 3")),
    .malformed(.invalidPoint(element: "trkpt", index: 41)),
    .malformed(.multipleSequences(element: "trkpt", count: 3)),
    .unusable(.tooFewWaypoints(count: 1)),
    .unusable(.routeWaypointOutOfRange(index: 2, latitude: 91, longitude: 0))
])
func everyFailureNamesTheFile(error: RouteFileError) {
    let alert = RouteFileDecision.alert(for: error, path: path)
    #expect(alert.body.contains(path))
    #expect(!alert.title.isEmpty)
}

/// No settings link on any of them: nothing in System Settings fixes a
/// GPX file, and sending someone there would show no answer.
@Test("no route failure offers a settings link", arguments: [
    RouteFileError.unreadable(message: "gone"),
    .malformed(.noPoints),
    .unusable(.tooFewWaypoints(count: 1))
])
func routeFailuresOfferNoSettingsLink(error: RouteFileError) {
    #expect(RouteFileDecision.alert(for: error, path: path).settingsURL == nil)
}

/// The underlying reason survives into the body rather than being
/// flattened to "couldn't read it".
@Test("the underlying reason reaches the user")
func underlyingReasonIsCarried() {
    let alert = RouteFileDecision.alert(
        for: .unreadable(message: "No such file or directory"),
        path: path
    )
    #expect(alert.body.contains("No such file or directory"))
}

/// A parse failure is restated in the user's terms. `GPXParseError`
/// names XML internals, which is the right vocabulary for a log and the
/// wrong one for an alert.
@Test("a parse failure is restated without XML jargon", arguments: [
    (GPXParseError.noPoints, "waypoints"),
    (.invalidPoint(element: "trkpt", index: 41), "trkpt number 42"),
    // Actionable, not descriptive: the fix is to split the file or drop
    // the outings they didn't mean, and neither is obvious from
    // "multiple sequences".
    (.multipleSequences(element: "trkpt", count: 3), "3 separate"),
    (.multipleSequences(element: "trkpt", count: 3), "merge them"),
    // The file's vocabulary, not the parser's: `rtept` is a route.
    (.multipleSequences(element: "rtept", count: 2), "route is broken")
])
func parseFailuresAreRestated(error: GPXParseError, needle: String) {
    let alert = RouteFileDecision.alert(for: .malformed(error), path: path)
    #expect(alert.body.contains(needle))
}

/// The defect's own sentence is reused, so the alert says exactly what
/// `pane.location.set` would have said and there is one wording to keep
/// right rather than two.
@Test("an unusable route reuses the daemon's own wording")
func unusableRouteReusesTheDefectMessage() {
    let defect = SimulatedLocationDefect.tooFewWaypoints(count: 1)
    let alert = RouteFileDecision.alert(for: .unusable(defect), path: path)
    #expect(alert.body.contains(defect.message))
}

/// Stops at "starting it failed" rather than claiming the device is
/// unchanged: a transport failure can land after the backend already
/// began playback. Same reasoning as `UseMyLocationDecision.applyFailure`.
@Test("a start failure does not claim the device is unchanged")
func startFailureMakesNoClaimAboutTheDevice() {
    let alert = RouteFileDecision.startFailure(reason: "device busy")
    #expect(alert.body.contains("device busy"))
    #expect(!alert.body.lowercased().contains("unchanged"))
    #expect(alert.settingsURL == nil)
}
