// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One thing to do to the device's human-interface surfaces, in deviceterm's own
/// vocabulary. The relay privately turns each intent into the device's HID /
/// button / orientation reports; nothing above it names a wire field.
package enum InteractionIntent: Sendable {
    case keyDown(KeyboardInput)
    case keyUp(KeyboardInput)
    /// A touchscreen action: a plain contact/lift, a live system-gesture edge
    /// drag, or the scripted App Switcher swipe (see `TouchInput.Kind`).
    case touch(TouchInput)
    /// One hardware-button phase; the caller times the hold between press and
    /// release.
    case button(ButtonInput)
    /// One relative 90° orientation step; the outcome reports where it landed.
    case rotate(RotationInput)
}
