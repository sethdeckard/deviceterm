// SPDX-License-Identifier: GPL-3.0-or-later
//
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

/// The result of performing an intent. Most intents just acknowledge; a rotate
/// reports the orientation the device settled on.
package enum InteractionOutcome: Sendable, Equatable {
    case acknowledged
    case orientation(String?)
}

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

/// A single key transition, addressed by HID Keyboard usage (page 0x07).
package struct KeyboardInput: Sendable, Equatable {
    package let usage: UInt16

    package init(usage: UInt16) {
        self.usage = usage
    }
}

/// A normalised touch coordinate, origin top-left, each axis 0…1 across the
/// display. The relay scales it into the device's native range when it builds a
/// report.
package struct DevicePoint: Sendable, Equatable {
    package let x: Double
    package let y: Double

    package init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A touchscreen action.
package struct TouchInput: Sendable, Equatable {
    /// Whether this is a contact/press sample or the final lift.
    package enum Phase: Sendable, Equatable {
        case contact
        case lift
    }

    /// How the touch is routed on the device.
    package enum Kind: Sendable, Equatable {
        /// A plain digitizer touch, which reaches the foreground app.
        case direct
        /// A live edge drag carrying the system-gesture trailer, so it reaches
        /// SpringBoard's home-indicator recognizer instead of the app.
        case systemGesture(GestureEdge)
        /// The scripted App Switcher swipe from `edge` (grab → ramp → dwell →
        /// lift). The relay drives the whole trajectory; `point`/`phase` are
        /// ignored for this kind.
        case appSwitcher(GestureEdge)
    }

    package let point: DevicePoint
    package let phase: Phase
    package let kind: Kind

    package init(point: DevicePoint, phase: Phase, kind: Kind) {
        self.point = point
        self.phase = phase
        self.kind = kind
    }
}

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

/// One relative 90° orientation step. `left` cycles portrait → landscapeLeft →
/// portraitUpsideDown → landscapeRight; `right` is the reverse.
package enum RotationInput: String, Sendable, Equatable {
    case left
    case right
}
