// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The engine's reported terminal
/// background color, as a Sendable value type. Emitted when
/// libghostty processes an OSC 11 background-color sequence. The
/// engine's `GHOSTTY_ACTION_COLOR_CHANGE` also carries FG and cursor
/// kinds; the bridge forwards only the background kind, so no other
/// kind reaches this type. The host uses it to keep color-aware chrome,
/// including the scrollbar appearance, in sync with the live terminal
/// background.
///
/// Three `UInt8` channels mirror the r/g/b of libghostty's
/// `ghostty_action_color_change_s` payload: no sRGB / gamma decode
/// at the value-type boundary; consumers convert when they need to.
public struct TerminalBackgroundColor: Sendable, Equatable, Hashable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}
