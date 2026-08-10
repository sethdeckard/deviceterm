// SPDX-License-Identifier: GPL-3.0-or-later
//
// ResolvedRefs: the typed projections `IntentResolver` returns
// after translating user-facing `TabRef` / `PaneRef` / `WindowRef`
// values to GUI-internal IDs. Structs (rather than tuples) so the
// fields are addressable by name at every call site, the resolver's
// signatures stay readable, and the `large_tuple` SwiftLint rule
// doesn't fire across the layer.

import Foundation

struct ResolvedTab {
    let windowID: WindowID
    let tabID: TabID
    let tab: TabState
}

struct ResolvedPane {
    let windowID: WindowID
    let tabID: TabID
    let pane: SimPaneState
}
