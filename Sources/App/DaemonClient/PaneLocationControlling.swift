// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// Role protocol: simulated GPS position on a pane's device.
///
/// Carved out so the location view model depends on just these two
/// calls rather than the broader `PaneControlling` surface, per the
/// per-role split the other narrow consumers follow.
///
/// Both methods are `.validatedGUI` on the wire, which is why this role
/// exists on the GUI side and nowhere else. The CLI has no location
/// verb, and a UDS caller cannot reach these methods even by hand-rolling
/// a frame.
@MainActor
protocol PaneLocationControlling: AnyObject {
    /// `pane.location.set`: apply a coordinate, a named scenario, a
    /// GPX route, or `.cleared` to the pane's device.
    func paneLocationSet(paneId: String, location: SimulatedLocation) async throws
    /// `pane.location.state`: what deviceterm last applied to this pane,
    /// plus the scenarios its device offers. The location is the daemon's
    /// own claim, not a device reading; neither backend has a getter.
    func paneLocationState(paneId: String) async throws -> PaneLocationStateResult
}
