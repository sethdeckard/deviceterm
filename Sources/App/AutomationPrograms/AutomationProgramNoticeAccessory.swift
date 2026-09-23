// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Builds the titlebar accessory that hosts the automation-program notice.
///
/// Separate from its owner for the reason `UpdatePillAccessory` is: in a file
/// importing SwiftUI the bare name `App` resolves to `SwiftUI.App` rather
/// than this module, which breaks the `App.observe` binding helper.
enum AutomationProgramNoticeAccessory {
    @MainActor
    static func make(
        viewModel: AutomationProgramNoticeViewModel
    ) -> NSTitlebarAccessoryViewController {
        let controller = NSTitlebarAccessoryViewController()
        controller.layoutAttribute = .right
        let host = NSHostingView(rootView: AutomationProgramNoticeView(viewModel: viewModel))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
        controller.view = host
        return controller
    }
}
