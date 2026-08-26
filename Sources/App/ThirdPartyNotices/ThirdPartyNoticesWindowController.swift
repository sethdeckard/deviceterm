// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The window for Help > Third-Party
/// Notices. Owns window lifecycle only; the SwiftUI `ThirdPartyNoticesView`
/// (driven by `ThirdPartyNoticesViewModel`) holds all presentation state.
/// `AppDelegate` keeps a single instance and re-fronts it, so repeat
/// invocations bring the same window forward instead of stacking.
@MainActor
final class ThirdPartyNoticesWindowController: NSWindowController {
    private let viewModel = ThirdPartyNoticesViewModel()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Third-Party Notices"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        viewModel.load()
        window.contentViewController = NSHostingController(
            rootView: ThirdPartyNoticesView(viewModel: viewModel)
        )
    }
}
