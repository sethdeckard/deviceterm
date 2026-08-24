// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

public enum DaemonInfo {
    /// The daemon's wire-version string. Returned in `daemon.ping`
    /// responses and compared by the GUI client against its own
    /// `DaemonProtocolInfo.wireVersion` (they mirror each other). A
    /// definite mismatch drives update recovery: the GUI issues
    /// `daemon.shutdown` to the incompatible daemon, awaits the ack,
    /// then surfaces the quit/reopen remediation so the next launch
    /// starts the helper from the updated bundle.
    public static let version = DaemonProtocolInfo.wireVersion
}
