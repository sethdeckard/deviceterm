// SPDX-License-Identifier: GPL-3.0-or-later
//
// The pane identifiers are an observability contract with the
// out-of-process UI-test harness, which selects the shared prefix and
// then follows one full identifier across dumps.
//
// The prefix is the discovery half: the harness fails loudly when it
// selects nothing, so a prefix change announces itself. The suffixes are
// the quieter half, since a reshaped one still matches the prefix and
// still counts. Uniqueness carries its own weight because the focus
// checks name panes by whole identifier: a collision makes two distinct
// pane nodes indistinguishable, and the harness can then no longer say
// which one a shortcut acted on.
//
// The accessibility-group test covers the rest of the contract: an
// identifier is only reachable if the view carrying it is published to
// the accessibility tree at all.

@testable import App
import AppKit
import DaemonProtocol
import Testing

@MainActor
struct PaneAccessibilityIdentityTests {
    @Test
    func eachSlotKindSpellsItselfOut() {
        let cases: [(PaneSlot, String)] = [
            (.terminal(TerminalPaneID(value: 7)), "deviceterm.pane.terminal.7"),
            (.sim(udid: "ABC-123"), "deviceterm.pane.sim.ABC-123"),
            (.device(deviceId: "dev-9"), "deviceterm.pane.device.dev-9"),
            (.pending(PendingPaneID(value: 2)), "deviceterm.pane.pending.2")
        ]
        for (slot, expected) in cases {
            #expect(PaneAccessibilityIdentity.identifier(for: slot) == expected)
        }
    }

    @Test
    func everyIdentifierSharesThePrefix() {
        // The harness selects pane nodes by prefix, so a kind that
        // dropped it would be uncountable.
        let slots: [PaneSlot] = [
            .terminal(TerminalPaneID(value: 1)),
            .sim(udid: "u"),
            .device(deviceId: "d"),
            .pending(PendingPaneID(value: 1))
        ]
        for slot in slots {
            let identifier = PaneAccessibilityIdentity.identifier(for: slot)
            #expect(identifier.hasPrefix(PaneAccessibilityIdentity.prefix + "."))
        }
    }

    @Test
    func everyPaneRootIsPublishedAsAnAccessibilityGroup() {
        // AppKit prunes a view that is not an accessibility element and
        // promotes its children, which would drop the identifier on the
        // floor. The two wrapper subclasses opt in explicitly. A pending
        // pane's root is an `NSHostingView`, which already answers group
        // and element on its own, so the layout controller sets only the
        // identifier there. That third row is inherited SwiftUI
        // behavior rather than something this code asserts, which is
        // exactly why it is pinned.
        let pending = PendingPaneViewController(
            pending: PendingPaneState(
                id: PendingPaneID(value: 1),
                target: .sim(udid: "U"),
                displayName: "iPhone",
                family: "phone"
            )
        )
        let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let roots: [(String, NSView)] = [
            ("terminal", TerminalPaneWrapperView(frame: frame)),
            ("sim/device", SimulatorPaneWrapperView(frame: frame)),
            ("pending", pending.view)
        ]
        for (kind, root) in roots {
            #expect(root.isAccessibilityElement(), "\(kind) pane root is not an accessibility element")
            #expect(root.accessibilityRole() == .group, "\(kind) pane root is not an AXGroup")
        }
    }

    @Test
    func distinctSlotsGetDistinctIdentifiers() {
        // A terminal and a pending pane can carry the same numeric id,
        // so the kind has to be part of the string or the two would
        // collide in a dump.
        let terminal = PaneAccessibilityIdentity.identifier(for: .terminal(TerminalPaneID(value: 4)))
        let pending = PaneAccessibilityIdentity.identifier(for: .pending(PendingPaneID(value: 4)))
        #expect(terminal != pending)
    }
}
