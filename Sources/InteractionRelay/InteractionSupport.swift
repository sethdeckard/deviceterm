// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which interaction surfaces a relay can drive, fixed when it is built from the
/// channels a device actually vends. Drives the daemon's per-verb capability
/// gate.
package struct InteractionSupport: Sendable, Equatable {
    package let touch: Bool
    package let keyboard: Bool
    package let buttons: Bool
    package let rotation: Bool

    package init(touch: Bool, keyboard: Bool, buttons: Bool, rotation: Bool) {
        self.touch = touch
        self.keyboard = keyboard
        self.buttons = buttons
        self.rotation = rotation
    }
}
