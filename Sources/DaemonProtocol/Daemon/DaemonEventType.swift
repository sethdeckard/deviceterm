// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum DaemonEventType {
    /// Pane lifecycle transition (booting / rendering / shutdown).
    /// Most common event source: agents watching for
    /// `state == "rendering"` get boot-wait without polling.
    public static let paneStateChanged = "pane.stateChanged"
    /// A device has booted (shim-intercept or external simctl boot
    /// detected by the daemon). Carries the UDID.
    public static let deviceBooted = "device.booted"
    /// A device has shut down. Carries the UDID.
    public static let deviceShutdown = "device.shutdown"
    /// A new session was minted via `session.create`. Carries the
    /// sessionId + shortId + optional name (the three-layer
    /// identifier model).
    public static let sessionCreated = "session.created"
    /// A session was closed via `session.close`. Carries the
    /// sessionId.
    public static let sessionClosed = "session.closed"
}
