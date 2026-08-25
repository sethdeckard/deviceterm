// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneCloseMode: how a pane (or session) close disposes of the
// underlying simulator. The `mode` wire value on `pane.close` /
// `session.close`. Shared so the GUI stops re-typing "detach" /
// "shutdown" and the daemon decodes the same enum.

public enum PaneCloseMode: String, Sendable, Codable, Equatable {
    /// Drop the pane but leave the underlying sim alone.
    case detach
    /// Drop the pane *and* shut down the sim. PaneCoordinator reports
    /// back via `close(...)`'s return value so the RPC layer can call
    /// `DeviceCoordinator.shutdown`, so pane lifecycle stays decoupled
    /// from device lifecycle.
    case shutdown
}
