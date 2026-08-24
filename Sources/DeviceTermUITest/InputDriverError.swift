// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum InputDriverError: Error, Equatable {
    case eventSourceUnavailable
    case eventCreationFailed
    case noMatchingElement(needle: String)
    case elementDoesNotSupportPress(needle: String)
    case pressFailed(needle: String)
    case noWindow(bundleID: String)
    case pointOutOfRange(x: Double, y: Double)
}
