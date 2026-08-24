// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

enum KeyShortcutError: Error, Equatable {
    case empty
    case unknownToken(String)
    case missingKey
    case multipleKeys(String, String)
}
