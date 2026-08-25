// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol
import Foundation

/// One translated key plus the modifier state needed to type it. A complete
/// text request is handed to the backend as one batch so a simulator can keep
/// another input request from interleaving between its key-down and key-up.
struct HIDKeystroke: Equatable, Sendable {
    let usage: UInt32
    let shift: Bool
}
