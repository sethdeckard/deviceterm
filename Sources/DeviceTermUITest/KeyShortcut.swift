// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// One parsed key combination: a virtual key code plus the
/// modifier flags to post with it. `KeyShortcutParser` produces it and
/// `InputDriver` turns it into a real CGEvent.
struct KeyShortcut: Equatable, Sendable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}
