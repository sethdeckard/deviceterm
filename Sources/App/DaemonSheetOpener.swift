// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ServiceManagement
import SwiftUI

/// Lightweight wrapper for opening system URLs. Injected so the
/// sheet's snapshot test can assert which URL was opened without
/// actually launching System Settings.
protocol DaemonSheetOpener: Sendable {
    func open(_ url: URL)
}
