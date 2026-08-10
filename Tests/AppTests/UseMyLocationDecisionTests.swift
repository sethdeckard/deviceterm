// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// UseMyLocationDecisionTests: every outcome of a location request maps
// to something the user can read.
//
// The rule worth protecting is totality. Use My Location is a menu item
// with no other feedback channel, so an outcome that produced no alert
// would look identical to a working one, and the user would have no way
// to tell a denial from a slow fix. The Settings link is the second
// rule: it appears only where there is something there to change.

@Test("a fix needs no alert")
func aFixProducesNoAlert() {
    #expect(UseMyLocationDecision.alert(for: .fix(latitude: 37.7749, longitude: -122.4194)) == nil)
}

@Test("every failure produces a readable alert", arguments: [
    MacLocationFix.notDetermined,
    .denied,
    .restricted,
    .unavailable("Location Services returned no position.")
])
func everyFailureProducesAnAlert(fix: MacLocationFix) throws {
    let alert = try #require(
        UseMyLocationDecision.alert(for: fix),
        "this outcome would leave the menu item looking like it did nothing"
    )
    #expect(!alert.title.isEmpty)
    #expect(!alert.body.isEmpty)
}

/// The two outcomes the user can actually resolve, and the only two that
/// should send them to System Settings.
@Test("permission failures link to Settings", arguments: [
    MacLocationFix.notDetermined,
    .denied
])
func permissionFailuresOfferTheSettingsLink(fix: MacLocationFix) {
    #expect(UseMyLocationDecision.alert(for: fix)?.settingsURL == UseMyLocationDecision.locationServicesURL)
}

/// Sending someone to Location Services for these would waste their time:
/// a restriction is set by policy and cannot be lifted there, and a
/// transient failure has nothing to do with permission at all.
@Test("failures the user can't act on offer no link", arguments: [
    MacLocationFix.restricted,
    .unavailable("The network connection was lost.")
])
func unactionableFailuresOfferNoLink(fix: MacLocationFix) {
    #expect(UseMyLocationDecision.alert(for: fix)?.settingsURL == nil)
}

/// The specific `unavailable` reason reaches the user verbatim. Those
/// reasons are what distinguish a missing usage description from an
/// empty result from a transport error, so generic wording would discard
/// the only detail that tells them apart.
@Test
func anUnavailableReasonIsShownVerbatim() {
    let reason = "Location Services returned no position."
    #expect(UseMyLocationDecision.alert(for: .unavailable(reason))?.body == reason)
}

/// A position that was taken but couldn't be applied is a different
/// story from one that never arrived: the Mac answered and the device
/// did not. It offers no Settings link, since permission was never the
/// problem, and it stops short of claiming the device's position is
/// unchanged, because a transport failure can land after the backend
/// already applied it.
@Test
func anApplyFailureReportsTheDeviceNotThePermission() {
    let alert = UseMyLocationDecision.applyFailure(reason: "device busy")
    #expect(alert.settingsURL == nil)
    #expect(alert.body.contains("device busy"))
    #expect(!alert.body.localizedCaseInsensitiveContains("unchanged"))
}

/// Pins the expected scheme and anchor, which is what catches a fallback
/// to the root file URL: `locationServicesURL` degrades to one rather
/// than force-unwrapping, so a typo in the literal would otherwise ship
/// as a button that opens the root directory. It cannot prove System
/// Settings accepts the identifier.
@Test
func theSettingsLinkIsASystemSettingsURL() {
    let url = UseMyLocationDecision.locationServicesURL
    #expect(url.scheme == "x-apple.systempreferences")
    #expect(url.absoluteString.hasSuffix("?Privacy_LocationServices"))
}
