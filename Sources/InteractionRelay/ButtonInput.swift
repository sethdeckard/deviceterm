// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One hardware-button phase. The control names the button without exposing its
/// HID usage; the relay resolves the usage page/code.
package struct ButtonInput: Sendable, Equatable {
    package enum Control: Sendable, Equatable {
        case home
        case power
        case assistant
    }

    package enum Phase: Sendable, Equatable {
        case press
        case release
    }

    package let control: Control
    package let phase: Phase

    package init(control: Control, phase: Phase) {
        self.control = control
        self.phase = phase
    }
}
