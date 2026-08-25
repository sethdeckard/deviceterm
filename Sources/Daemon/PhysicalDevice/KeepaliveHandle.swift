// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A live keepalive subprocess. `Process` conforms in production; tests
/// substitute a fake to exercise ref-counting without spawning anything.
protocol KeepaliveHandle: AnyObject {
    var isRunning: Bool { get }
    func interrupt()
}
