// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire-contract identity shared by every process
/// that speaks the daemon RPC (daemon, GUI client, deviceterm-cli, shim).
///
/// `wireVersion` mirrors the daemon's `DaemonInfo.version`. The daemon
/// returns it in `daemon.ping`; the GUI client compares it on connect
/// and runs the graceful version-mismatch shutdown/respawn handshake
/// when a Sparkle update has moved the daemon bundle. Keeping the
/// constant in the shared module means client and server can't drift
/// to two different literals. It is internal bundle-coordination state,
/// independent of the public DeviceTerm release version.
public enum DaemonProtocolInfo {
    /// The RPC wire-version string. Must equal the daemon's
    /// `DaemonInfo.version` (`Sources/Daemon/DaemonInfo.swift`).
    /// Wire version 0.6.0 defines singular `window.*`, `tab.*`, and `pane.*`
    /// method families. Reads return the
    /// GUI's live window/tab/pane projection, mutations return committed
    /// objects, and terminal input/capture address a pane explicitly.
    /// `tab.open` and `pane.split` await terminal session creation;
    /// terminal pane IDs are session IDs. The daemon-direct device roster is
    /// internal `pane.deviceList`; grant revocation is lifecycle-only.
    /// Every process speaking this version ships and updates in the same
    /// bundle.
    public static let wireVersion = "0.6.0"
}
