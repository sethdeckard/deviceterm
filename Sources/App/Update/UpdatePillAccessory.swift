// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Builds the titlebar accessory that hosts the update pill.
///
/// Separate from `UpdateController` so that controller need not import
/// SwiftUI: it is an `NSObject` subclass, as Sparkle's delegate protocol
/// requires, and in a file importing SwiftUI the bare name `App` resolves to
/// `SwiftUI.App` rather than this module, which breaks the `App.observe`
/// binding helper the controller depends on.
enum UpdatePillAccessory {
    @MainActor
    static func make(viewModel: UpdateViewModel) -> NSTitlebarAccessoryViewController {
        let controller = NSTitlebarAccessoryViewController()
        controller.layoutAttribute = .right
        let host = NSHostingView(rootView: UpdatePillView(viewModel: viewModel))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
        controller.view = host
        return controller
    }
}
