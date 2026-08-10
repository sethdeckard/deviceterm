// SPDX-License-Identifier: GPL-3.0-or-later
//
// ScrollbarState: libghostty's "where is the viewport in the
// scrollback?" snapshot, mirrored as a Sendable value type so the
// host can observe it without linking the libghostty C framework.
//
// The engine emits this through `GHOSTTY_ACTION_SCROLLBAR` whenever
// the scrollback grows (new output extends `total`), the viewport
// moves (user scrolls or the terminal alt-screen flips), or layout
// changes the visible row count (`len`). The host turns it into
// scrollbar geometry: `SurfaceScrollView` sizes its document view
// to `total` rows and positions its visible rect at `offset`.
//
// Field semantics match `ghostty_action_scrollbar_s` (libghostty
// C header `ghostty.h`): all three are `UInt64` to mirror the wire
// shape exactly, no signedness drift across the bridge:
//
//   - total:  rows in scrollback + the active screen
//   - offset: first visible row index (0 = top of history)
//   - len:    visible row count (viewport height in rows)
//
// `len + offset` may exceed `total` momentarily during resize races
// (renderer emits a SCROLLBAR mid-resize); consumers should clamp
// when computing geometry rather than assert.

import Foundation

public struct ScrollbarState: Sendable, Equatable, Hashable {
    /// The default before the engine emits its first SCROLLBAR
    /// action. All zeros, so a consumer comparing against `.empty`
    /// knows it hasn't received a real update yet.
    public static let empty = ScrollbarState(total: 0, offset: 0, len: 0)

    public let total: UInt64
    public let offset: UInt64
    public let len: UInt64

    public init(total: UInt64, offset: UInt64, len: UInt64) {
        self.total = total
        self.offset = offset
        self.len = len
    }
}
