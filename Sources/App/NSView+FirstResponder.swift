// SPDX-License-Identifier: GPL-3.0-or-later
//
// A non-conformance extension, so it does not follow the "conformances
// live on the primary type" rule: `NSView` is AppKit's, and this adds
// one shared query rather than a protocol.
//
// Both pane wrapper views need to know whether keyboard focus is inside
// them, and neither can find out by being asked. The view that actually
// holds first responder is a descendant: libghostty's surface for a
// terminal, the Metal content view for a device. Walking the view tree
// upward from the first responder is the load-bearing relation, rather
// than `nextResponder`, because "focus is inside this pane" is a
// containment question.

import AppKit

extension NSView {
    /// Whether the window's first responder is this view or lives inside
    /// it. False when the view is not in a window, which is also the
    /// right answer for a pane that has been detached.
    func containsFirstResponder() -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        var current: NSView? = responder
        while let view = current {
            if view === self { return true }
            current = view.superview
        }
        return false
    }
}
