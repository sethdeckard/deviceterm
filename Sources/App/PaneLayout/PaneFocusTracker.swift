// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Resolves "keyboard focus is inside this pane" from the window's
/// responder chain, for a pane root that cannot be asked directly.
///
/// The first responder is normally an embedded view: libghostty's
/// surface for a terminal, the Metal content view for a device. The
/// terminal's belongs to a foreign module this codebase does not
/// subclass, so there is no `becomeFirstResponder` to override and call
/// back from. The containment query also covers the pane root itself,
/// which is what holds focus before an input target exists.
///
/// `NSWindow.didUpdateNotification` provides a window-scoped refresh
/// point. On each notification the tracker re-reads
/// `containsFirstResponder()` and reports only changes, so unchanged
/// state does not invoke the callback.
///
/// Re-resolving from `viewDidMoveToWindow(_:)` is what lets a detached
/// pane answer false. AppKit drops the window's first responder when a
/// first-responder view leaves the hierarchy, and does it without
/// routing through `makeFirstResponder`, so no `resignFirstResponder`
/// arrives and a flag driven only by responder callbacks can remain
/// true while the pane is detached.
///
/// The owner passes the view into each call, so the tracker stores no
/// view reference and cannot extend its owner's lifetime.
@MainActor
final class PaneFocusTracker {
    /// Fires on each resolved change, with the new state. Never fires
    /// for an unchanged answer, so an adopter can treat a `true` as the
    /// focus-gained edge.
    var onFocusChange: ((Bool) -> Void)?
    /// The last resolved answer. Adopters paint from this rather than
    /// keeping a second copy that could disagree with it.
    private(set) var isFocused = false

    /// `nonisolated(unsafe)` because the nonisolated deinit has to read
    /// it to unregister (`NSObjectProtocol` isn't `Sendable`, so a
    /// plain main-actor property would be unreachable there). Every
    /// other access is on the main actor, and
    /// `NotificationCenter.removeObserver` is thread-safe, so the
    /// deinit's snapshot needs no further synchronization.
    nonisolated(unsafe) private var windowObserver: NSObjectProtocol?

    /// Unregister if the tracked view is released while still mounted.
    /// AppKit doesn't reliably call `viewDidMoveToWindow()` with a nil
    /// window when a closing window releases its view tree wholesale, so
    /// the move-driven path alone can leak one observer per pane
    /// lifecycle.
    nonisolated deinit {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }

    /// Call from the tracked view's `viewDidMoveToWindow()`. Re-arms the
    /// observer against the view's current window (the notification is
    /// registered per window, so a pane moved between windows would
    /// otherwise keep watching the old one) and re-resolves immediately.
    ///
    /// One unconditional `refresh` covers both directions: a windowless
    /// view has no first responder to contain, so the same call that
    /// picks up focus on mount is the one that clears it on removal.
    func viewDidMoveToWindow(_ view: NSView) {
        removeObserver()
        if let window = view.window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { @Sendable [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.refresh(for: view)
                }
            }
        }
        refresh(for: view)
    }

    /// Re-read the responder chain and report only an actual change.
    func refresh(for view: NSView) {
        let focused = view.containsFirstResponder()
        guard focused != isFocused else { return }
        isFocused = focused
        onFocusChange?(focused)
    }

    private func removeObserver() {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
        windowObserver = nil
    }
}
