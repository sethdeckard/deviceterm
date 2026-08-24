// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// A device-ownership consequence of a cohort transition, applied to
/// `DeviceCoordinator` by the effect pump. Daemon-internal, never on the wire.
///
/// The two kinds are distinct types, not one struct with nullable targets:
/// a close and a transfer authorize very different sweeps, and keeping them
/// apart is what guarantees every close records a tombstone even when panes
/// move.
enum CohortDeviceEffect: Sendable, Equatable {
    /// The session is genuinely going away: tombstone it, re-home or
    /// disposition its boot claims, and move (or release) everything it owns.
    case close(CohortCloseEffect)
    /// A reconcile dropped a still-live member: move only the named devices
    /// and their matching claims. No tombstone and no wider sweep; the
    /// session is alive, and its unrelated devices and late claims stay its
    /// own.
    case transfer(CohortTransferEffect)
}
