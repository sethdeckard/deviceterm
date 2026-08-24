// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation

/// One CoreSimulator notification paired with the instant it arrived.
///
/// The consumer handles events serially and a handler can run long, so
/// "now" inside a handler is not when the notification landed. The publish
/// debounce compares source timestamps, and for the notification path that
/// timestamp is callback arrival rather than handler processing time.
/// Otherwise a slow handler stretches the apparent gap and a duplicate
/// queued right behind the first reads as a fresh transition.
struct NotifierArrival: Sendable {
    let event: CSBNotifierEvent
    let arrivedAt: Date
}
