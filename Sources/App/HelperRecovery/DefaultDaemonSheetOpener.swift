// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ServiceManagement
import SwiftUI

struct DefaultDaemonSheetOpener: DaemonSheetOpener {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
