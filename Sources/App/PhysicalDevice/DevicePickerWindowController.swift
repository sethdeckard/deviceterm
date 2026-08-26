// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// A small transient window hosting the
/// SwiftUI `DevicePickerView`. "Mirror Physical Device…" can be invoked
/// from the menu bar, so the picker gets its own utility window (mirrors
/// `SettingsPromptWindowController`). The window is closed by whoever
/// wired the view model's attach / cancel callbacks (AppDelegate) once
/// the user picks a device or cancels; this controller just builds and
/// shows it.
@MainActor
final class DevicePickerWindowController: NSWindowController {
    init(viewModel: DevicePickerViewModel) {
        let window = NSWindow(
            // Starting size for the loading state; the window resizes to
            // fit as the SwiftUI content reports its height (devices load
            // async, so the populated height isn't known at show time).
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeviceTerm"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        let view = DevicePickerView(viewModel: viewModel) { [weak self] height in
            self?.fitWindow(toContentHeight: height)
        }
        window.contentViewController = NSHostingController(rootView: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Show the picker and bring it to the front.
    func showPicker() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Resize the window so its content area is exactly `height` tall
    /// (width is fixed at 380), keeping the top-left corner fixed so the
    /// window grows downward rather than jumping. Called whenever the
    /// SwiftUI content's measured height changes.
    private func fitWindow(toContentHeight height: CGFloat) {
        guard let window else { return }
        let contentRect = NSRect(x: 0, y: 0, width: 380, height: max(120, ceil(height)))
        let target = window.frameRect(forContentRect: contentRect)
        var frame = window.frame
        let topLeftY = frame.maxY
        frame.size = target.size
        frame.origin.y = topLeftY - target.height
        window.setFrame(frame, display: true, animate: false)
    }
}
