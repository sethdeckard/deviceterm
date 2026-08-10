// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Unique socket path in a temp directory. `prefix` becomes part of
/// the filename so failing-test artifacts are easy to associate with
/// the test that created them (e.g. `deviceterm-paneinp-…`). Caller is
/// responsible for stopping the server (which unlinks), or for
/// `unlink`ing manually if construction fails before the server takes
/// ownership.
///
/// Path is kept short: macOS's UDS struct caps `sun_path` at 104
/// bytes, NSTemporaryDirectory already chews most of that, and the
/// test PID + an 8-char UUID suffix gets us collision-free without
/// blowing the cap.
public func tempSocketPath(prefix: String = "deviceterm") -> String {
    let dir = NSTemporaryDirectory()
    let suffix = UUID().uuidString.prefix(8)
    return "\(dir)\(prefix)-\(getpid())-\(suffix).sock"
}
