// SPDX-License-Identifier: GPL-3.0-or-later

/// How far a location request has got.
enum LocationRequestPhase: Equatable, Sendable {
    /// Nothing is waiting on a permission answer.
    case idle
    /// Waiting for the manager's first status report.
    ///
    /// A freshly built `CLLocationManager` has not synced with the
    /// location daemon yet, and until it has, both `authorizationStatus`
    /// and `requestWhenInUseAuthorization()` are unreliable: the status
    /// can read `notDetermined` for an app that is already decided, and
    /// the request can be dropped with no prompt and no callback. That
    /// first report is the manager saying it is ready, which is why it
    /// starts a request rather than being filtered out as noise.
    case awaitingReady
    /// Waiting for the user to answer the permission prompt.
    case awaitingAuthorization
    /// Permission is settled and a position is on its way.
    case awaitingFix
}
