// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// What one `devicectl` invocation produced: its exit status, the
/// contents of the `--json-output` file (nil when it wrote none), and
/// whatever it put on stderr.
struct DeviceCtlRun: Sendable {
    let status: Int32
    let json: Data?
    let stderr: String
}
