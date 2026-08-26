// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The typed tab projection `IntentResolver` returns after translating a
/// user-facing `TabRef` to GUI-internal IDs. A struct rather than a tuple
/// so the fields are addressable by name at every call site, the
/// resolver's signatures stay readable, and the `large_tuple` SwiftLint
/// rule doesn't fire across the layer.
struct ResolvedTab {
    let windowID: WindowID
    let tabID: TabID
    let tab: TabState
}
