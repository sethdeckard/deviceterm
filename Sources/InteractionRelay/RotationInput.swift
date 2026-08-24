// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One relative 90° orientation step. `left` cycles portrait → landscapeLeft →
/// portraitUpsideDown → landscapeRight; `right` is the reverse.
package enum RotationInput: String, Sendable, Equatable {
    case left
    case right
}
