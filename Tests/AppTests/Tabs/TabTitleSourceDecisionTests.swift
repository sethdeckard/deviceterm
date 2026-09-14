// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Testing

@testable import App

@Suite("tab title source resolution")
struct TabTitleSourceDecisionTests {
    private let primary = TerminalPaneID(value: 1)
    private let second = TerminalPaneID(value: 2)

    @Test
    func fallsBackToThePrimaryWhenNoTerminalHasBeenFocused() {
        // A freshly opened tab has both memories empty and still needs a
        // terminal to read a title from.
        let source = TabTitleSourceDecision.source(
            lastFocusedPane: nil,
            lastFocusedTerminal: nil,
            primaryTerminal: primary,
            leaves: [.terminal(primary)],
            pendingTargets: []
        )
        #expect(source.terminal == primary)
        #expect(source.device == nil)
    }

    @Test
    func followsTheLastFocusedTerminal() {
        let source = TabTitleSourceDecision.source(
            lastFocusedPane: .terminal(second),
            lastFocusedTerminal: second,
            primaryTerminal: primary,
            leaves: [.terminal(primary), .terminal(second)],
            pendingTargets: []
        )
        #expect(source.terminal == second)
        #expect(source.device == nil)
    }

    @Test
    func fallsBackToThePrimaryWhenTheFocusedTerminalIsGone() {
        // The memory is cleared on the one path that removes a terminal, so
        // this pins the defensive fallback for a terminal absent from the tree.
        let source = TabTitleSourceDecision.source(
            lastFocusedPane: .terminal(second),
            lastFocusedTerminal: second,
            primaryTerminal: primary,
            leaves: [.terminal(primary)],
            pendingTargets: []
        )
        #expect(source.terminal == primary)
    }

    @Test
    func reportsTheFocusedSimPane() {
        let source = TabTitleSourceDecision.source(
            lastFocusedPane: .sim(udid: "UDID-1"),
            lastFocusedTerminal: primary,
            primaryTerminal: primary,
            leaves: [.terminal(primary), .sim(udid: "UDID-1")],
            pendingTargets: []
        )
        #expect(source.device == .sim(udid: "UDID-1"))
    }

    @Test
    func reportsTheFocusedDevicePane() {
        let source = TabTitleSourceDecision.source(
            lastFocusedPane: .device(deviceId: "DEV-1"),
            lastFocusedTerminal: primary,
            primaryTerminal: primary,
            leaves: [.terminal(primary), .device(deviceId: "DEV-1")],
            pendingTargets: []
        )
        #expect(source.device == .device(deviceId: "DEV-1"))
    }

    @Test
    func keepsTheTerminalBindingWhileADevicePaneIsFocused() {
        // The two answers are independent: the device names the tab on screen
        // while the terminal keeps feeding the daemon-side title cache, which
        // a device name has no business being written into.
        let source = TabTitleSourceDecision.source(
            lastFocusedPane: .sim(udid: "UDID-1"),
            lastFocusedTerminal: second,
            primaryTerminal: primary,
            leaves: [.terminal(primary), .terminal(second), .sim(udid: "UDID-1")],
            pendingTargets: []
        )
        #expect(source.terminal == second)
        #expect(source.device == .sim(udid: "UDID-1"))
    }

    @Test
    func reportsNoDeviceWhileATerminalHoldsFocus() {
        let source = TabTitleSourceDecision.source(
            lastFocusedPane: .terminal(primary),
            lastFocusedTerminal: primary,
            primaryTerminal: primary,
            leaves: [.terminal(primary), .sim(udid: "UDID-1")],
            pendingTargets: []
        )
        #expect(source.device == nil)
    }

    @Test
    func ignoresARememberedPaneThatHasLeftTheTree() {
        // Nothing clears the remembered pane when it closes, so a detached sim
        // must not keep naming the tab.
        let source = TabTitleSourceDecision.source(
            lastFocusedPane: .sim(udid: "UDID-1"),
            lastFocusedTerminal: primary,
            primaryTerminal: primary,
            leaves: [.terminal(primary)],
            pendingTargets: []
        )
        #expect(source.terminal == primary)
        #expect(source.device == nil)
    }

    @Test
    func keepsTheFocusedDeviceThroughAReattach() {
        // A re-attach trades the sim's leaf for a pending one and drops its
        // record. The remembered slot is the same sim, so the label has to
        // hold rather than fall back to the terminal and bounce again.
        let source = TabTitleSourceDecision.source(
            lastFocusedPane: .sim(udid: "UDID-1"),
            lastFocusedTerminal: primary,
            primaryTerminal: primary,
            leaves: [.terminal(primary), .pending(PendingPaneID(value: 7))],
            pendingTargets: [.sim(udid: "UDID-1")]
        )
        #expect(source.device == .sim(udid: "UDID-1"))
    }

    @Test
    func ignoresAPendingSlot() {
        // A pending slot carries no target, so this resolver has no device to
        // name. `lastFocusedPane` never holds one; this pins the handling if
        // it ever did.
        let pending = PendingPaneID(value: 7)
        let source = TabTitleSourceDecision.source(
            lastFocusedPane: .pending(pending),
            lastFocusedTerminal: primary,
            primaryTerminal: primary,
            leaves: [.terminal(primary), .pending(pending)],
            pendingTargets: [.sim(udid: "UDID-1")]
        )
        #expect(source.device == nil)
    }
}
