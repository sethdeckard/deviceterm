// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The window a `WelcomeMessage` is shown in.
/// Owns presentation lifecycle only; the message supplies the content.
///
/// A standalone window, shown at launch *before* the first DeviceTerm
/// window exists, so the welcome is the first thing on screen rather
/// than something competing with the app behind it. That ordering also
/// settles what it can't be: there is no window to host a sheet yet.
///
/// `onFinished` fires exactly once however the window goes away, by the
/// content's button or by another close request such as ⌘W, because the
/// launch sequence waits on it to open the main window. Dropping it
/// would leave the app running with no window.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    /// Called once when the window closes. Set by the coordinator.
    var onFinished: (() -> Void)?

    /// Guards `onFinished` against a second call: `close()` from the
    /// content button also produces a `windowWillClose`.
    private var hasFinished = false

    init(message: WelcomeMessage, presentation: WelcomePresentation) {
        let window = NSWindow(
            // Resized to the content's fitting size below; this only
            // needs to be close enough to avoid a visible reflow.
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Chromeless, like Apple's own first-run screens: content runs
        // to the top edge and the traffic lights are hidden, so the
        // button is the way out. `.closable` stays in the mask purely so
        // ⌘W still works as an escape hatch; without it a wedged window
        // would leave the app running with no main window, because the
        // launch sequence waits on this closing.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        // Kept for the Window menu and accessibility even though the
        // title bar doesn't draw it.
        window.title = message.title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        // Built after `super.init` so the dismiss action can capture
        // self. Weak, because the content is retained by the window this
        // controller owns.
        let host = NSHostingController(
            rootView: message.content(presentation) { [weak self] in self?.close() }
        )
        window.contentViewController = host
        // Cap to the screen so a long message, a short display, or an
        // enlarged text size can't produce a window taller than the
        // space available. The content scrolls when it doesn't fit and
        // its button stays pinned, so the way forward survives the
        // clamp. Without this the window would size to the content's
        // full height and hang its bottom off the screen, which on a
        // window that gates app startup means no visible way forward.
        let fitting = host.view.fittingSize
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? fitting.height
        window.setContentSize(
            NSSize(width: fitting.width, height: min(fitting.height, available - 40))
        )
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Show the window and bring it to the front, activating the app so
    /// it isn't buried by whatever had focus while DeviceTerm launched.
    func showWelcome() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard !hasFinished else { return }
        hasFinished = true
        onFinished?()
    }
}
