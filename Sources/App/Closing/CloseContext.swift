// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Carries the prompt-time context the dropdown options/default are
/// derived from. `windowID` is nil for the quit prompt.
struct CloseContext: Sendable {
    let windowID: WindowID?
    let hasOtherTabsInWindow: Bool
}
