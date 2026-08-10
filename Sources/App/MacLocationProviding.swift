// SPDX-License-Identifier: GPL-3.0-or-later
//
// MacLocationProviding: this Mac's own position, for Device ▸ Location ▸
// Use My Location.
//
// A protocol so `PaneLocationViewModel` can be tested with a fake and
// never touches CoreLocation or the authorization prompt.
// `CoreLocationProvider` is the only production conformer.

/// The outcome of one request for this Mac's position.
///
/// The failures stay separate rather than collapsing into a single case
/// because each is a different thing to tell the user, and two of them
/// (`notDetermined` and `denied`) are the ones a trip to Privacy &
/// Security can resolve. `UseMyLocationDecision` maps each to its own
/// alert, so the menu item never fails silently.
enum MacLocationFix: Equatable, Sendable {
    /// A position in degrees, as CoreLocation reported it.
    case fix(latitude: Double, longitude: Double)
    /// macOS has not been told whether DeviceTerm may read the Mac's
    /// location, and asking did not settle it.
    case notDetermined
    /// The user declined, or Location Services is off.
    case denied
    /// Policy (a configuration profile, Screen Time) forbids it. The
    /// user cannot grant it from Settings, so its alert offers no link
    /// there.
    case restricted
    /// CoreLocation was asked and could not answer. Carries its own
    /// description of why.
    case unavailable(String)
}

/// One-shot access to the Mac's position.
///
/// `@MainActor` because the only implementation drives
/// `CLLocationManager`, whose delegate callbacks arrive on the thread
/// that created it, and because its single caller is a main-actor view
/// model.
@MainActor
protocol MacLocationProviding {
    /// One position, or why there isn't one.
    ///
    /// Requests authorization on first use when permission is not yet
    /// determined, and **never throws**:
    /// every failure is a `MacLocationFix` case the caller can show. A
    /// menu item that silently did nothing would be the worst outcome
    /// here, since the user has no other signal that it ran.
    func currentFix() async -> MacLocationFix
}
