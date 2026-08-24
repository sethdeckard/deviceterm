// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct CaptureOutcome: Sendable {
    let path: String
    let width: Int
    let height: Int
    let scale: Double
}
