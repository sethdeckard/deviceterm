// SPDX-License-Identifier: GPL-3.0-or-later
/// The screen edge a home-indicator / App Switcher system gesture originates
/// from, in the device's native (portrait) frame.
///
/// iOS draws the home indicator along the bottom of the *current* interface
/// orientation, so the native originating edge rotates with the device:
/// portrait → bottom, landscape-left → the native left, landscape-right → the
/// native right. The daemon decides which edge a gesture uses and passes it in;
/// this target turns it into the per-edge report trailer and swipe trajectory.
package enum GestureEdge: Sendable, Equatable {
    case bottom
    case left
    case right

    /// The 8-byte system-gesture trailer that occupies report bytes 50–57. Byte
    /// 50 is a per-gesture contact id the recognizer ignores (held at 0x03);
    /// bytes 51–53 are constant; bytes 54–57 encode the edge, and SpringBoard's
    /// recognizer rejects a swipe whose trailer edge disagrees with the device's
    /// current orientation.
    var trailer: [UInt8] {
        switch self {
        case .bottom:
            [0x03, 0x00, 0x00, 0x20, 0x04, 0x00, 0x00, 0x00]

        case .left:
            [0x03, 0x00, 0x00, 0x20, 0x00, 0x00, 0x02, 0x00]

        case .right:
            [0x03, 0x00, 0x00, 0x20, 0x00, 0x10, 0x00, 0x00]
        }
    }

    /// The device-native uint16 grab point for the scripted App Switcher swipe:
    /// on the home-indicator edge, centred along the cross axis.
    var grabPoint: (x: UInt16, y: UInt16) {
        switch self {
        case .bottom:
            (0x7C00, 0xFFFF)

        case .left:
            (0x0000, 0x8000)

        case .right:
            (0xFFFF, 0x8000)
        }
    }

    /// The held point ~0.22 in from the edge toward centre, where the dwell fans
    /// the App Switcher out rather than committing to Home.
    var dwellPoint: (x: UInt16, y: UInt16) {
        switch self {
        case .bottom:
            (0x7C00, 0xC800)

        case .left:
            (0x37FF, 0x8000)

        case .right:
            (0xC800, 0x8000)
        }
    }
}
