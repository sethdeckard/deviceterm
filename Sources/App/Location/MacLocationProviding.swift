// SPDX-License-Identifier: GPL-3.0-or-later

/// One-shot access to the Mac's position, for Device ▸ Location ▸ Use My
/// Location.
///
/// A protocol so `PaneLocationViewModel` can be tested with a fake and
/// never touches CoreLocation or the authorization prompt.
/// `CoreLocationProvider` is the only production conformer.
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
