// SPDX-License-Identifier: GPL-3.0-or-later

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
