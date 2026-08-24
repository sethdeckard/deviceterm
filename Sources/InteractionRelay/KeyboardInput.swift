// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A single key transition, addressed by HID Keyboard usage (page 0x07).
package struct KeyboardInput: Sendable, Equatable {
    package let usage: UInt16

    package init(usage: UInt16) {
        self.usage = usage
    }
}
