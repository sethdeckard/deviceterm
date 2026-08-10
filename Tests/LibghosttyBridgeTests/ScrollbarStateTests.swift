// SPDX-License-Identifier: GPL-3.0-or-later

import TerminalSurface
import Testing

// ScrollbarState mirrors libghostty's `ghostty_action_scrollbar_s`
// payload as a Sendable Swift value type. The bridge module decodes
// the C struct into this type in `GhosttyRuntime.ghosttyAction`'s
// SCROLLBAR branch; the App layer consumes it via
// `TerminalSurfaceDelegate.terminalSurface(_:didUpdateScrollbar:)`
// without linking GhosttyKit. These tests pin value semantics +
// edge cases the geometry math will rely on (notably: consumers
// must clamp `offset + len` against `total`, not assert).

@Test
func storesFieldsExactly() {
    let state = ScrollbarState(total: 10_000, offset: 9_500, len: 40)
    #expect(state.total == 10_000)
    #expect(state.offset == 9_500)
    #expect(state.len == 40)
}

@Test
func equalityIsValueBased() {
    let one = ScrollbarState(total: 100, offset: 0, len: 24)
    let two = ScrollbarState(total: 100, offset: 0, len: 24)
    let three = ScrollbarState(total: 100, offset: 1, len: 24)
    #expect(one == two)
    #expect(one != three)
    #expect(one.hashValue == two.hashValue)
}

@Test
func emptyIsAllZero() {
    let state = ScrollbarState.empty
    #expect(state.total == 0)
    #expect(state.offset == 0)
    #expect(state.len == 0)
    #expect(state == ScrollbarState(total: 0, offset: 0, len: 0))
}

@Test
func roundTripsUInt64Max() {
    // libghostty's payload is UInt64; the bridge must not silently
    // narrow. A degenerate "all max" value is the canary for any
    // accidental Int / Int32 truncation along the path.
    let state = ScrollbarState(
        total: UInt64.max,
        offset: UInt64.max,
        len: UInt64.max
    )
    #expect(state.total == UInt64.max)
    #expect(state.offset == UInt64.max)
    #expect(state.len == UInt64.max)
}

@Test
func toleratesOffsetPlusLenExceedingTotal() {
    // Mid-resize the renderer can emit a SCROLLBAR where offset + len
    // overshoots total briefly. The value type doesn't enforce the
    // invariant; consumers (SurfaceScrollView's geometry math)
    // clamp. Pin that this is legal to construct.
    let state = ScrollbarState(total: 100, offset: 99, len: 40)
    #expect(state.offset + state.len > state.total)
}

@Test
func sendableValueCrossesActorBoundaries() async {
    // Compile-time check that ScrollbarState satisfies Sendable so
    // the bridge can pass it from action_cb (called inside
    // ghostty_app_tick on main, but the type may travel to other
    // observers). The test runs the value through a Task boundary;
    // any future change that breaks Sendable would fail to compile.
    let state = ScrollbarState(total: 42, offset: 7, len: 24)
    let echoed = await Task { state }.value
    #expect(echoed == state)
}
