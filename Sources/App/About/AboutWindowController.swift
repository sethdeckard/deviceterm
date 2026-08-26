// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The window for the app-menu "About DeviceTerm"
/// item, replacing `orderFrontStandardAboutPanel`. Owns window lifecycle
/// only; `AboutView` (fed a resolved `AboutInfo`) holds the content.
/// `AppDelegate` keeps a single instance and re-fronts it, so repeat
/// invocations bring the same window forward instead of stacking. Mirrors
/// `ThirdPartyNoticesWindowController`.
@MainActor
final class AboutWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "About DeviceTerm"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        let host = NSHostingController(rootView: AboutView(info: .current()))
        window.contentViewController = host
        // Size the window to the SwiftUI content's fitting height.
        window.setContentSize(host.view.fittingSize)
        window.center()
    }
}
