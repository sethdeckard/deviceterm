// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// A small transient window hosting the
/// SwiftUI `ConfigCreatePromptView`. Settings… can be invoked from the
/// app menu with no window open, so the create-confirmation gets its own
/// utility window rather than a sheet on a (possibly absent) key window.
///
/// The window is closed by whoever wired the view model's
/// `onPromptResolved` callback (AppDelegate) once the user picks Create
/// or Cancel; this controller just builds and shows it.
@MainActor
final class SettingsPromptWindowController: NSWindowController {
    init(viewModel: ConfigSettingsViewModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 168),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "DeviceTerm"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentViewController = NSHostingController(
            rootView: ConfigCreatePromptView(viewModel: viewModel)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Show the prompt and bring it to the front.
    func showPrompt() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
