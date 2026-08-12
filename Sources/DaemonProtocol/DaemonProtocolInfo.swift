// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonProtocolInfo: wire-contract identity shared by every process
// that speaks the daemon RPC (daemon, GUI client, deviceterm-cli, shim).
//
// `wireVersion` mirrors the daemon's `DaemonInfo.version`. The daemon
// returns it in `daemon.ping`; the GUI client compares it on connect
// and runs the graceful version-mismatch shutdown/respawn handshake
// when a Sparkle update has moved the daemon bundle. Keeping the
// constant in the shared module means client and server can't drift
// to two different literals. It is internal bundle-coordination state,
// independent of the public DeviceTerm release version.

public enum DaemonProtocolInfo {
    /// The RPC wire-version string. Must equal the daemon's
    /// `DaemonInfo.version` (`Sources/Daemon/DaemonMethods.swift`).
    /// Bumped to 0.2.0 by the `attachment` admission id: `pane.create` /
    /// `device.attach` / `physicalDevice.attach` return it, and
    /// `pane.closeById` accepts it as `expectedAttachment`.
    public static let wireVersion = "0.2.0"
}
