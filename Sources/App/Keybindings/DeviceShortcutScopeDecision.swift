// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Whether a device-scoped item is offered
/// on the path it was invoked from.
///
/// Both paths run through `validateUserInterfaceItem`, so that is where
/// the two are told apart. During key-equivalent dispatch AppKit is
/// inside `sendEvent(_:)`, so `NSApp.currentEvent` is the raw keyDown and
/// its chord matches the item's. Menu tracking runs its own loop and
/// exposes a mouse event instead. Keyboard menu navigation also yields a
/// keyDown, but its chord is Return rather than the item's, so comparing
/// chords rather than only asking "is this a keyDown" keeps it on the
/// pointer side where it belongs.
///
/// Unknown events default to `.pointerOrMenu`, which preserves menu and
/// accessibility activation. A misclassified key equivalent lands there
/// too, so it leaves the fallback enabled and can dispatch to the tab's
/// first device pane rather than to the pane holding focus.
@MainActor
enum DeviceShortcutScopeDecision {
    static func origin(currentEvent: NSEvent?, chord: KeyChord) -> MenuActionOrigin {
        // keyDown only. `KeyChord.matches` accepts keyUp as well, which
        // the device pane's HID guard needs on both edges and this does
        // not: key-equivalent routing runs on the keyDown, so a keyUp
        // reaching here names some other path and belongs on the pointer
        // side.
        guard let currentEvent,
            currentEvent.type == .keyDown,
            chord.matches(currentEvent) else {
            return .pointerOrMenu
        }
        return .keyEquivalent
    }

    /// Whether `PaneLayoutViewController`'s responder-chain fallback should
    /// offer an item of `scope` invoked from `origin`.
    ///
    /// Reaching that fallback already means the focused pane declined
    /// the selector, so no device pane holds focus. A device-scoped
    /// chord pressed there is aimed at whatever the user is typing into,
    /// and AppKit hands a disabled item's event down to that pane rather
    /// than swallowing it. Clicking the same item is an explicit choice
    /// with no other reading, so the pointer path keeps the fallback.
    static func fallbackAllows(scope: KeybindingScope, origin: MenuActionOrigin) -> Bool {
        switch scope {
        case .app:
            return true

        case .devicePane:
            return origin == .pointerOrMenu
        }
    }
}
