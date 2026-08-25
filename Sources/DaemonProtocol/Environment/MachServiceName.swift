// SPDX-License-Identifier: GPL-3.0-or-later
//
// MachServiceName: single source of truth for the mach service name
// the daemon vends and the GUI connects to over XPC.
//
// Read by:
//   - The daemon's mach-service listener bind call.
//   - The GUI's XPC connection-create call.
//   - LaunchAgentPlistTests, which asserts the LaunchAgent plist's
//     `MachServices` top-level key equals this constant verbatim
//     (drift between the plist and the Swift constant is a CI
//     failure).
//
// Lives in `DaemonProtocol` so the host app target can read it
// without taking a dependency on `Daemon`.

import Foundation

public enum MachServiceName {
    /// Mach service name the daemon vends and the GUI client
    /// connects to. Matches the bundle-id convention
    /// `<host>.daemon.xpc`.
    public static let daemon: String = "com.deviceterm.daemon.xpc"
}
