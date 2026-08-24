// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A status-item capture: the badge window, or a report that no matching
/// badge window is present.
enum StatusItemCapture: Sendable {
    case present(CaptureOutcome)
    case absent
}
