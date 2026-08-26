// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// What a verb reports when the pane's contact lane refuses it. Refusal
// sends nothing at all, so the question these ask is whether the caller
// can tell that from a gesture that landed.

/// Drive a pane into the state where its lane refuses every composite: a
/// gesture whose sends fail leaves a contact whose state is unknown, and
/// the lane stays shut until a release lands. `failReleaseHeldContact`
/// keeps the abandonment timer from reopening it under a slow run.
private func wedgedPane(
    _ coordinator: PaneCoordinator,
    backend: MockDeviceBackend,
    udid: String
) async throws -> UUID {
    backend.failSends = true
    backend.failReleaseHeldContact = true
    let pane = try await coordinator.createMockPane(
        udid: udid,
        sessionId: UUID(),
        backend: backend
    )
    await #expect(throws: PaneError.self) {
        try await coordinator.tap(paneId: pane.paneId, as: .guiPeer, x: 0.5, y: 0.5)
    }
    // The sends threw before recording, so anything the lane admits from
    // here would show up in these.
    #expect(backend.tapDownPoints.isEmpty)
    backend.failSends = false
    return pane.paneId
}

@Test
func aRefusedEdgeSwipeReportsRefusalRatherThanOk() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let paneId = try await wedgedPane(coordinator, backend: backend, udid: "refused-edge-swipe")

    await #expect(throws: PaneError.inputNotAdmitted(paneId: paneId, operation: .edgeSwipe)) {
        try await coordinator.edgeSwipe(
            paneId: paneId,
            as: .guiPeer,
            fromX: 0.5,
            fromY: 0.99,
            toX: 0.5,
            toY: 0.5,
            durationMs: 200,
            holdMs: 100
        )
    }
    #expect(backend.edgeDownPoints.isEmpty)
    #expect(backend.edgeMovePoints.isEmpty)
    #expect(backend.edgeUpPoints.isEmpty)
}

@Test
func aRefusedBareAckGestureNamesItsOwnVerb() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let paneId = try await wedgedPane(coordinator, backend: backend, udid: "refused-siblings")

    // Every verb whose ack is a bare `ok` has the same problem and takes
    // the same answer, and each has to name itself so the message points
    // at the call the caller made.
    await #expect(throws: PaneError.inputNotAdmitted(paneId: paneId, operation: .tap)) {
        try await coordinator.tap(paneId: paneId, as: .guiPeer, x: 0.5, y: 0.5)
    }
    await #expect(throws: PaneError.inputNotAdmitted(paneId: paneId, operation: .longPress)) {
        try await coordinator.longPress(paneId: paneId, as: .guiPeer, x: 0.5, y: 0.5, durationMs: 400)
    }
    await #expect(throws: PaneError.inputNotAdmitted(paneId: paneId, operation: .pinch)) {
        try await coordinator.pinch(
            paneId: paneId,
            as: .guiPeer,
            fromF1X: 0.4,
            fromF1Y: 0.4,
            fromF2X: 0.6,
            fromF2Y: 0.6,
            toF1X: 0.3,
            toF1Y: 0.3,
            toF2X: 0.7,
            toF2Y: 0.7,
            durationMs: 200
        )
    }
    #expect(backend.tapDownPoints.isEmpty)
    #expect(backend.tapUpPoints.isEmpty)
}

@Test
func aRefusedSwipeReportsZeroSamplesRatherThanThrowing() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let paneId = try await wedgedPane(coordinator, backend: backend, udid: "refused-swipe")

    // Swipe is the one verb whose ack can carry a refusal, so it answers
    // with the sample count instead of an error. Pinned here because the
    // sibling verbs above deliberately behave differently.
    let outcome = try await coordinator.swipe(
        paneId: paneId,
        as: .guiPeer,
        fromX: 0.2,
        fromY: 0.2,
        toX: 0.8,
        toY: 0.8,
        durationMs: 200
    )
    #expect(outcome.steps == 0)
    #expect(backend.tapDownPoints.isEmpty)
}

@Test
func aRefusedLiveContactReportsRefusalRatherThanOk() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let paneId = try await wedgedPane(coordinator, backend: backend, udid: "refused-live")

    await #expect(throws: PaneError.inputNotAdmitted(paneId: paneId, operation: .touch)) {
        try await coordinator.touch(paneId: paneId, as: .guiPeer, x: 0.5, y: 0.5, phase: .down)
    }
    await #expect(throws: PaneError.inputNotAdmitted(paneId: paneId, operation: .touch)) {
        try await coordinator.touch(paneId: paneId, as: .guiPeer, x: 0.6, y: 0.6, phase: .move)
    }
    await #expect(throws: PaneError.inputNotAdmitted(paneId: paneId, operation: .multitouch)) {
        try await coordinator.multitouch(
            paneId: paneId,
            as: .guiPeer,
            phase: .down,
            points: [CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.6)]
        )
    }
    #expect(backend.tapDownPoints.isEmpty)
}

@Test
func aDroppedLiftStaysSilent() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let paneId = try await wedgedPane(coordinator, backend: backend, udid: "dropped-lift")

    // The wedged composite holds the lane and owns recovering its contact,
    // so a live lift has no lease of its own to release and is neither
    // admitted nor forwarded. Nothing was owed, so nothing is reported.
    try await coordinator.touch(paneId: paneId, as: .guiPeer, x: 0.5, y: 0.5, phase: .lift)
    #expect(backend.tapUpPoints.isEmpty)
}

@Test
func aRefusedEdgePressLeavesNoLatchBehind() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let paneId = try await wedgedPane(coordinator, backend: backend, udid: "refused-edge-press")

    await #expect(throws: PaneError.inputNotAdmitted(paneId: paneId, operation: .edgeTouch)) {
        try await coordinator.edgeTouch(paneId: paneId, as: .guiPeer, x: 0.5, y: 0.99, phase: .down)
    }
    // The press never opened a contact, so the move after it has nothing to
    // continue and returns without reaching the lane at all. A latch left
    // over from the refused press would instead carry it through as an
    // edge-tagged drag, which is what this catches: with one, the lane
    // refuses the move and this throws.
    try await coordinator.edgeTouch(paneId: paneId, as: .guiPeer, x: 0.5, y: 0.5, phase: .move)
    #expect(backend.edgeDownPoints.isEmpty)
    #expect(backend.edgeMovePoints.isEmpty)
}

@Test
func anEdgePressWhoseSendFailedKeepsItsLatch() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(
        udid: "ambiguous-edge-press",
        sessionId: UUID(),
        backend: backend
    )
    // The lane admits this press and names the contact it opened, so the
    // send failing leaves the device's state unknown rather than proving
    // nothing went out.
    backend.failSends = true
    await #expect(throws: PaneError.self) {
        try await coordinator.edgeTouch(paneId: pane.paneId, as: .guiPeer, x: 0.5, y: 0.99, phase: .down)
    }

    // The caller's own lift is the fastest way to free that contact, and it
    // only gets there through the latch. Dropping the latch on an ambiguous
    // failure would send this down the no-press branch and leave the finger
    // down until the lane's abandonment timer recovered it.
    backend.failSends = false
    try await coordinator.edgeTouch(paneId: pane.paneId, as: .guiPeer, x: 0.5, y: 0.99, phase: .lift)
    #expect(backend.edgeUpPoints.count == 1)
}

@Test
func aGestureWhosePaneMovedMidFlightIsNotAcknowledged() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(
        udid: "superseded-gesture",
        sessionId: UUID(),
        backend: backend
    )
    // A transfer bumps the pane's input generation, and both backends then
    // drop the old generation's sends and return normally. The lane admits
    // the gesture and it runs to completion, and only the generation check
    // afterwards stops the daemon acknowledging it. This fake doesn't gate
    // its own primitives on the flag, so it still records the down; what is
    // under test is the coordinator's refusal to acknowledge, not the drop.
    backend.inputGenerationCurrent = false

    await #expect(throws: PaneError.inputSuperseded(paneId: pane.paneId, operation: .tap)) {
        try await coordinator.tap(paneId: pane.paneId, as: .guiPeer, x: 0.5, y: 0.5)
    }
}

@Test
func aSupersededGestureReportsAmbiguityRatherThanAVerdict() {
    let mapped = PaneMethods.mapPaneError(
        .inputSuperseded(paneId: UUID(), operation: .tap)
    )
    #expect(mapped.code == RPCErrorCode.serverError)
    #expect(mapped.message.contains("pane.tap"))
    // Neither of the two verdicts it would be wrong to state. The barrier
    // runs several steps before the ownership commit and the transfer can
    // still abort, so this can't say ownership changed; and sends that
    // completed before the bump landed, so it can't wave the caller into a
    // retry either. It reports the overlap and leaves both open.
    #expect(!mapped.message.contains("retry"))
    #expect(!mapped.message.contains("ownership change"))
    #expect(mapped.message.contains("delivery is unknown"))
    #expect(
        PaneError.inputSuperseded(paneId: UUID(), operation: .tap).diagnosticKind
            == "input-superseded:tap"
    )
}

@Test
func aTransferDropsAnOpenEdgeDragsLatch() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let owner = UUID()
    let pane = try await coordinator.createMockPane(
        udid: "transferred-edge-drag",
        sessionId: owner,
        backend: backend
    )
    try await coordinator.edgeTouch(paneId: pane.paneId, as: .guiPeer, x: 0.5, y: 0.99, phase: .down)
    #expect(backend.edgeDownPoints.count == 1)

    // Adopting the pane out of a dead owner runs the transfer barrier, which
    // drops the drag's lane lease and clears the coordinator's edge latch.
    // This fake takes the protocol's no-op quiesce, so nothing here models
    // releasing the contact itself; the latch is what's under test.
    _ = try await coordinator.createMockPane(
        udid: "transferred-edge-drag",
        sessionId: UUID(),
        backend: backend,
        isOwnerSessionAlive: { $0 != owner }
    )

    // The cleared latch leaves the move with no drag to continue. With the
    // latch still standing it would open a fresh lease and send an edge drag
    // from a press the lane no longer has a lease for.
    try await coordinator.edgeTouch(paneId: pane.paneId, as: .guiPeer, x: 0.5, y: 0.5, phase: .move)
    #expect(backend.edgeMovePoints.isEmpty)
}

@Test
func aRefusedGestureIsRetryableAndNamesTheVerbOnTheWire() {
    let paneId = UUID()
    let mapped = PaneMethods.mapPaneError(
        .inputNotAdmitted(paneId: paneId, operation: .edgeSwipe)
    )
    #expect(mapped.code == RPCErrorCode.serverError)
    #expect(mapped.message.contains("pane.edgeSwipe"))
    // The caller has to be able to tell "nothing went out" from "it went
    // out and failed", because only one of those is safe to repeat.
    #expect(mapped.message.contains("nothing was sent"))
    #expect(!mapped.message.contains(paneId.uuidString))
}

@Test
func aRefusedGestureLogsItsVerbWithoutIdentifiers() {
    let kind = PaneError.inputNotAdmitted(paneId: UUID(), operation: .pinch).diagnosticKind
    #expect(kind == "input-not-admitted:pinch")
}
