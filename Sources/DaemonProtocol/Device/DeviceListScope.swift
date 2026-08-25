// SPDX-License-Identifier: GPL-3.0-or-later

/// The `device.list` `scope` parameter. Shared so the
/// GUI/CLI and daemon spell it once. `CaseIterable` backs the daemon's
/// validation error message.
public enum DeviceListScope: String, Sendable, Equatable, CaseIterable {
    /// Sims this daemon booted / owns on behalf of some session.
    case owned
    /// Every sim CoreSimulator knows about.
    case all
}
