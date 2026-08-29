// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// The location coordinator entry points and their RPC handlers.
//
// Two rules carry most of the weight here and are each pinned by their
// own test: the tracked value moves ONLY after the backend confirms
// (otherwise the menu's checkmark advertises a position the device
// refused), and every lifecycle event that ends deviceterm's control of
// a device drops the claim to `nil` (otherwise a pane comes back
// asserting a position deviceterm can no longer vouch for). `nil` means
// "unknown", never "cleared": no clear is ever sent, and no getter
// exists to check.

/// A backend that supports location and records what it was told.
/// Distinct from `MockDeviceBackend`, which deliberately takes the
/// protocol's throwing defaults to model an unwired backend.
private final class LocationMockBackend: DeviceBackend, @unchecked Sendable {
    let capabilities: DeviceBackendCapabilities = .simulator
    private(set) var coordinates: [(latitude: Double, longitude: Double)] = []
    private(set) var scenarios: [String] = []
    private(set) var routes: [RouteSpec] = []
    private(set) var clearCount = 0
    private(set) var enumerationCount = 0
    /// Names `setSimulatedLocationScenario` rejects, mirroring a backend
    /// that pre-validates against its own list.
    var knownScenarios = ["City Run", "Freeway Drive"]
    /// When set, every setter throws it.
    var failure: DeviceBackendError?
    /// When set, every setter throws it *untyped*, the shape a raw
    /// CoreSimulator bridge `NSError` takes on its way out.
    var rawFailure: (any Error)?
    /// When set, enumeration throws it.
    var enumerationFailure: DeviceBackendError?

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) {}
    func stopFrames() {}
    func pixelDimensions() -> (Int?, Int?) { (390, 844) }

    // No display or reply to observe; rotation confirmation is unsupported.
    func startDisplayOrientation(onChange: @escaping @Sendable (Orientation) -> Void) -> Bool { false }
    func stopDisplayOrientation() {}
    func currentDisplayOrientation() -> Orientation? { nil }
    func tapDown(at point: CGPoint, generation: UInt64) {}
    func tapUp(at point: CGPoint, generation: UInt64) {}
    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) {}
    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) {}
    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) {}
    func rotate(
        target: RotationTarget,
        confirmedOrientation: Orientation?,
        generation: UInt64
    ) -> BackendRotationOutcome {
        .confirmationUnsupported(target: target.orientation)
    }
    func keyDown(hidUsage: UInt32, generation: UInt64) {}
    func keyUp(hidUsage: UInt32, generation: UInt64) {}
    func rotateCrown(delta: Double, generation: UInt64) {}
    func accessibilityFrontmostTree() -> [String: Any] { [:] }
    func accessibilityElement(at pixelPoint: CGPoint) -> [String: Any] { [:] }
    func shutdownBackend() {}

    // swiftlint:disable async_without_await
    func setSimulatedLocation(latitude: Double, longitude: Double, generation: UInt64) async throws {
        if let rawFailure { throw rawFailure }
        if let failure { throw failure }
        coordinates.append((latitude, longitude))
    }

    func setSimulatedLocationScenario(_ name: String, generation: UInt64) async throws {
        if let rawFailure { throw rawFailure }
        if let failure { throw failure }
        guard knownScenarios.contains(name) else {
            throw DeviceBackendError.unknownLocationScenario(name: name)
        }
        scenarios.append(name)
    }

    func startSimulatedLocationRoute(_ spec: RouteSpec, generation: UInt64) async throws {
        if let rawFailure { throw rawFailure }
        if let failure { throw failure }
        routes.append(spec)
    }

    func clearSimulatedLocation(generation: UInt64) async throws {
        if let rawFailure { throw rawFailure }
        if let failure { throw failure }
        clearCount += 1
    }

    func availableLocationScenarios() async throws -> [String] {
        enumerationCount += 1
        if let enumerationFailure { throw enumerationFailure }
        return knownScenarios
    }
    // swiftlint:enable async_without_await
}

private extension PaneCoordinator {
    func createLocationPane(
        sessionId: UUID,
        backend: any DeviceBackend,
        udid: String = "udid-loc",
        isOwnerSessionAlive: (@Sendable (UUID) async -> Bool)? = nil
    ) async throws -> PaneCreateResult {
        try await createPane(
            target: .sim(udid: udid),
            sessionId: sessionId,
            isOwnerSessionAlive: isOwnerSessionAlive,
            acquire: { AcquiredBackend(backend: backend, family: "phone", deviceType: "iPhone") }
        )
    }
}

// MARK: - set

@Test("each location case reaches its own backend call")
func setLocationDispatchesPerCase() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)

    try await coordinator.setLocation(
        paneId: pane.paneId,
        as: principal,
        to: .coordinate(latitude: 37.3349, longitude: -122.009)
    )
    try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .scenario(name: "City Run"))
    try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .route(spec: validRoute))
    try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .cleared)

    #expect(backend.coordinates.count == 1)
    #expect(backend.coordinates.first?.latitude == 37.3349)
    #expect(backend.scenarios == ["City Run"])
    #expect(backend.routes == [validRoute])
    #expect(backend.clearCount == 1)
}

private let validRoute = RouteSpec(
    mode: .interval(seconds: 1),
    speed: 20,
    waypoints: [
        RouteWaypoint(latitude: 37.3349, longitude: -122.009),
        RouteWaypoint(latitude: 37.3359, longitude: -122.008)
    ]
)

@Test("a successful set becomes the tracked location")
func setLocationRecordsTheClaim() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)

    // A fresh pane carries no claim: deviceterm hasn't written anything,
    // and an attached device may already be simulating something.
    let state = try await coordinator.locationState(paneId: pane.paneId, as: principal)
    #expect(state.location == nil)

    try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .scenario(name: "Freeway Drive"))
    let after = try await coordinator.locationState(paneId: pane.paneId, as: principal)
    #expect(after.location == .scenario(name: "Freeway Drive"))
}

/// The rule that keeps the menu honest: the checkmark must never move
/// onto a location the device rejected.
@Test("a failed set leaves the tracked location untouched")
func failedSetDoesNotMoveTheClaim() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)

    try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .scenario(name: "City Run"))
    await #expect(throws: (any Error).self) {
        try await coordinator.setLocation(
            paneId: pane.paneId,
            as: principal,
            to: .scenario(name: "Not A Real Trip")
        )
    }
    let state = try await coordinator.locationState(paneId: pane.paneId, as: principal)
    #expect(state.location == .scenario(name: "City Run"))
}

@Test("an unknown scenario surfaces as unknownLocationScenario")
func unknownScenarioMapsToItsOwnError() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)

    await #expect(throws: PaneError.unknownLocationScenario(paneId: pane.paneId, name: "Nope")) {
        try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .scenario(name: "Nope"))
    }
}

/// A raw bridge error is not a `DeviceBackendError`, so without a
/// general catch it escapes the typed mapping and reaches the wire as
/// the catch-all `serverError` instead of `bridgeFailed`, losing the
/// "the bridge spoke up" signal machine consumers dispatch on.
@Test("a raw bridge error still maps to bridgeFailed")
func rawBridgeErrorMapsToBridgeFailed() async throws {
    struct RawBridgeFailure: Error {}
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    backend.rawFailure = RawBridgeFailure()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)

    do {
        try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .cleared)
        Issue.record("expected the raw bridge failure to throw")
    } catch let PaneError.bridgeFailed(_, operation, _) {
        #expect(operation == .locationSet)
    }
}

/// A command that failed while *running* must report the verb the caller
/// invoked. Borrowing `locationUnavailable` would label a failed
/// `pane.location.set` as `pane.location.acquire`, telling the client
/// acquisition failed for an operation that got past acquisition fine.
@Test("a failed command reports the caller's operation, not acquire")
func failedCommandReportsTheCallersOperation() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    backend.failure = .locationCommandFailed(message: "devicectl exited 1")
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)

    do {
        try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .cleared)
        Issue.record("expected the failed command to throw")
    } catch let PaneError.bridgeFailed(_, operation, message) {
        #expect(operation == .locationSet)
        #expect(message == "devicectl exited 1")
    }
}

/// Acquisition failure keeps its fixed label, so the two stay
/// distinguishable on the wire.
@Test("an acquisition failure still reports location.acquire")
func acquisitionFailureKeepsItsLabel() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    backend.failure = .locationUnavailable(message: "no location client")
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)

    do {
        try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .cleared)
        Issue.record("expected the acquisition failure to throw")
    } catch let PaneError.bridgeFailed(_, operation, _) {
        #expect(operation == .locationAcquire)
    }
}

/// A backend that took the protocol's throwing defaults reports
/// `location: false`, so the capability gate refuses before dispatch.
@Test("a backend without location support refuses the operation")
func backendWithoutLocationIsRefused() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createLocationPane(
        sessionId: session,
        backend: backend,
        udid: "udid-nl"
    )
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)

    await #expect(throws: PaneError.unsupportedOperation(paneId: pane.paneId, operation: .locationSet)) {
        try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .cleared)
    }
}

@Test("a foreign session can't set a pane's location")
func foreignSessionIsRefused() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)

    await #expect(throws: PaneError.notFound(paneId: pane.paneId)) {
        try await coordinator.setLocation(
            paneId: pane.paneId,
            as: .session(UUID(), incarnation: nil),
            to: .cleared
        )
    }
}

// MARK: - state

@Test("state reports the device's scenarios")
func stateReportsScenarios() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let state = try await coordinator.locationState(
        paneId: pane.paneId,
        as: .session(session, incarnation: nil)
    )
    #expect(state.scenarios == ["City Run", "Freeway Drive"])
}

/// Structural failure degrades to an empty list like any other, because
/// the read must stay total for the menu. It must still be *reachable*
/// as a distinct error first, so the coordinator can complain about it
/// instead of silently reporting "no trips": schema drift must remain
/// distinguishable before the menu read degrades. If
/// `locationOutputMalformed` ever collapses back into
/// `locationUnavailable`, the diagnosis is gone.
@Test("malformed enumeration output is a distinguishable failure")
func malformedEnumerationIsDistinguishable() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)

    backend.enumerationFailure = .locationOutputMalformed(message: "schema drift")
    // The backend surfaces it as its own case…
    do {
        _ = try await backend.availableLocationScenarios()
        Issue.record("expected the malformed enumeration to throw")
    } catch DeviceBackendError.locationOutputMalformed {
        // …which is what the coordinator keys its diagnosis on.
    }
    // …and the read still answers, so the menu keeps working.
    let state = try await coordinator.locationState(paneId: pane.paneId, as: principal)
    #expect(state.scenarios.isEmpty)
}

/// Enumeration failure degrades to an empty list rather than throwing,
/// so the tracked location, the part the daemon always knows, still
/// reaches the menu. A throw here would cost the checkmark.
@Test("a failed enumeration still reports the tracked location")
func failedEnumerationKeepsTheClaim() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)
    try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .scenario(name: "City Run"))

    backend.enumerationFailure = .locationUnavailable(message: "device went away")
    let state = try await coordinator.locationState(paneId: pane.paneId, as: principal)
    #expect(state.scenarios.isEmpty)
    #expect(state.location == .scenario(name: "City Run"))
}

/// A read must answer for a pane whose device is gone, because the menu
/// is built from it. `gatesInput: false` is what allows that.
@Test("state answers for a shut-down pane instead of faulting")
func stateAnswersForAShutDownPane() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)
    try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .scenario(name: "City Run"))

    await coordinator.markPanesShutdown(forUDID: "udid-loc")
    let state = try await coordinator.locationState(paneId: pane.paneId, as: principal)
    #expect(state.location == nil)
    #expect(state.scenarios.isEmpty)
}

// MARK: - Reset sites

@Test("a shutdown drops the claim")
func shutdownDropsTheClaim() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)
    try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .scenario(name: "City Run"))

    await coordinator.markPanesShutdown(forUDID: "udid-loc")
    let state = try await coordinator.locationState(paneId: pane.paneId, as: principal)
    // `nil`, not `.cleared`: nothing was told to clear, so claiming the
    // simulation was cleared would be a lie.
    #expect(state.location == nil)
    #expect(backend.clearCount == 0)
}

@Test("a failure drops the claim")
func failureDropsTheClaim() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)
    try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .scenario(name: "City Run"))

    await coordinator.markPaneFailed(paneId: pane.paneId, reason: "surface pool exhausted")
    let state = try await coordinator.locationState(paneId: pane.paneId, as: principal)
    #expect(state.location == nil)
    #expect(backend.clearCount == 0)
}

/// The complement of the transfer rule, and the reason the reset is
/// keyed on the transfer *commit* rather than on re-attachment: a
/// same-session re-attach is idempotent, the owner and its writes are
/// unchanged, so the claim it made about its own device still stands.
@Test("a same-session re-attach preserves the claim")
func sameSessionReAttachKeepsTheClaim() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)
    try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .scenario(name: "City Run"))

    let reattached = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    #expect(reattached.paneId == pane.paneId)

    let state = try await coordinator.locationState(paneId: pane.paneId, as: principal)
    #expect(state.location == .scenario(name: "City Run"))
}

/// A new owner must not inherit the prior owner's claim: it describes a
/// write the new owner never made.
@Test("an ownership transfer drops the claim")
func ownershipTransferDropsTheClaim() async throws {
    let coordinator = PaneCoordinator()
    let firstOwner = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: firstOwner, backend: backend)
    try await coordinator.setLocation(
        paneId: pane.paneId,
        as: .session(firstOwner, incarnation: nil),
        to: .scenario(name: "City Run")
    )

    // Re-create against the same target from a different session with
    // the prior owner reported dead: the coordinator adopts the orphan
    // and transfers ownership rather than refusing.
    let secondOwner = UUID()
    let adopted = try await coordinator.createLocationPane(
        sessionId: secondOwner,
        backend: backend,
        isOwnerSessionAlive: { _ in false }
    )
    #expect(adopted.paneId == pane.paneId)

    // The new owner inherits no claim, and reads `nil` rather than
    // `.cleared`: the transfer sent no clear, so nothing about the
    // device's position can be inferred from it.
    let state = try await coordinator.locationState(
        paneId: pane.paneId,
        as: .session(secondOwner, incarnation: nil)
    )
    #expect(state.location == nil)
    #expect(backend.clearCount == 0)
}

// MARK: - Ordering and the commit fence

/// A location backend whose setters park until released, so a test can
/// hold a command mid-flight and interleave another operation.
private actor LocationGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var entered = 0
    /// Commands that made it *through* the gate, in device order. Held
    /// here (rather than on the backend) so the recording is serialized by
    /// the same actor the test already awaits.
    private(set) var completed: [String] = []

    func enter() async {
        entered += 1
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func record(_ command: String) { completed.append(command) }

    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private final class ParkingLocationBackend: DeviceBackend, @unchecked Sendable {
    let capabilities: DeviceBackendCapabilities = .simulator
    private let gate: LocationGate
    /// When set, scenario *enumeration* parks on this instead of
    /// returning, so a test can hold a `locationState` read mid-flight.
    private let enumerationGate: LocationGate?
    /// Makes the ownership-transfer quiesce report failure, which aborts
    /// the transfer after it has already bumped `epoch`.
    private let failQuiesce: Bool

    init(gate: LocationGate, enumerationGate: LocationGate? = nil, failQuiesce: Bool = false) {
        self.gate = gate
        self.enumerationGate = enumerationGate
        self.failQuiesce = failQuiesce
    }

    // swiftlint:disable:next async_without_await
    func quiesceInputForTransfer() async -> Bool { !failQuiesce }

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) {}
    func stopFrames() {}
    func pixelDimensions() -> (Int?, Int?) { (390, 844) }

    // No display or reply to observe; rotation confirmation is unsupported.
    func startDisplayOrientation(onChange: @escaping @Sendable (Orientation) -> Void) -> Bool { false }
    func stopDisplayOrientation() {}
    func currentDisplayOrientation() -> Orientation? { nil }
    func tapDown(at point: CGPoint, generation: UInt64) {}
    func tapUp(at point: CGPoint, generation: UInt64) {}
    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) {}
    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) {}
    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) {}
    func rotate(
        target: RotationTarget,
        confirmedOrientation: Orientation?,
        generation: UInt64
    ) -> BackendRotationOutcome {
        .confirmationUnsupported(target: target.orientation)
    }
    func keyDown(hidUsage: UInt32, generation: UInt64) {}
    func keyUp(hidUsage: UInt32, generation: UInt64) {}
    func rotateCrown(delta: Double, generation: UInt64) {}
    func accessibilityFrontmostTree() -> [String: Any] { [:] }
    func accessibilityElement(at pixelPoint: CGPoint) -> [String: Any] { [:] }
    func shutdownBackend() {}

    func setSimulatedLocationScenario(_ name: String, generation: UInt64) async {
        await gate.enter()
        await gate.record(name)
    }

    func availableLocationScenarios() async -> [String] {
        await enumerationGate?.enter()
        return ["City Run", "Freeway Drive"]
    }

    // swiftlint:disable async_without_await
    func setSimulatedLocation(latitude: Double, longitude: Double, generation: UInt64) async {}
    func clearSimulatedLocation(generation: UInt64) async {}
    // swiftlint:enable async_without_await
}

/// Location commands serialize per pane. Without the chain, the second
/// set would reach the backend while the first is still parked, and the
/// two claim commits could then land in either order, leaving the
/// checkmark on a location the device isn't at.
@Test("a second location set waits for the first to finish")
func locationSetsSerializePerPane() async throws {
    let gate = LocationGate()
    let backend = ParkingLocationBackend(gate: gate)
    let coordinator = PaneCoordinator()
    let session = UUID()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)

    let first = Task {
        try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .scenario(name: "City Run"))
    }
    // Let the first reach the backend and park there.
    while await gate.entered < 1 { await Task.yield() }

    let second = Task {
        try await coordinator.setLocation(
            paneId: pane.paneId,
            as: principal,
            to: .scenario(name: "Freeway Drive")
        )
    }
    // Give the second every chance to jump the queue.
    for _ in 0..<50 { await Task.yield() }
    let mid = await gate.completed
    #expect(mid.isEmpty, "the second set must not reach the device while the first is parked")
    #expect(await gate.entered == 1, "the second set jumped the queue")

    await gate.release()
    try await first.value
    try await second.value
    #expect(await gate.completed == ["City Run", "Freeway Drive"])
    let state = try await coordinator.locationState(paneId: pane.paneId, as: principal)
    #expect(state.location == .scenario(name: "Freeway Drive"))
}

/// The commit fence. Location runs as `.guiPeer`, which `authorize`
/// admits for any live record, so re-authorizing after the backend call
/// is not enough: a set issued before an ownership transfer would sail
/// through and re-stamp a claim onto a pane the transfer had just
/// dropped one from. The `locationEpoch` check is what stops it.
@Test("a set in flight across an ownership transfer does not resurrect its claim")
func inFlightSetLosesToAnOwnershipTransfer() async throws {
    let gate = LocationGate()
    let backend = ParkingLocationBackend(gate: gate)
    let coordinator = PaneCoordinator()
    let firstOwner = UUID()
    let pane = try await coordinator.createLocationPane(sessionId: firstOwner, backend: backend)

    // A validated-GUI set, parked inside the backend.
    let inFlight = Task {
        try await coordinator.setLocation(paneId: pane.paneId, as: .guiPeer, to: .scenario(name: "City Run"))
    }
    while await gate.entered < 1 { await Task.yield() }

    // Ownership moves while that set is still parked.
    let secondOwner = UUID()
    let adopted = try await coordinator.createLocationPane(
        sessionId: secondOwner,
        backend: backend,
        isOwnerSessionAlive: { _ in false }
    )
    #expect(adopted.paneId == pane.paneId)

    await gate.release()
    try await inFlight.value

    // The transfer reset the claim, and the late commit must not undo that.
    let state = try await coordinator.locationState(paneId: pane.paneId, as: .guiPeer)
    #expect(state.location == nil)
}

/// The other half of the fence: a transfer that *aborts* must not cost a
/// claim. `epoch` is bumped speculatively when a transfer starts and is
/// never restored on abort, so fencing on it would discard a location
/// that reached the device while leaving the owner and backend untouched
/// so the menu would point at a location the device has moved away
/// from, the failure the fence exists to prevent. `locationEpoch`
/// advances only on committed changes, so the claim survives.
@Test("an aborted ownership transfer does not discard a successful claim")
func abortedTransferKeepsTheClaim() async throws {
    let gate = LocationGate()
    let backend = ParkingLocationBackend(gate: gate, failQuiesce: true)
    let coordinator = PaneCoordinator()
    let owner = UUID()
    let pane = try await coordinator.createLocationPane(sessionId: owner, backend: backend)

    let inFlight = Task {
        try await coordinator.setLocation(paneId: pane.paneId, as: .guiPeer, to: .scenario(name: "City Run"))
    }
    while await gate.entered < 1 { await Task.yield() }

    // Adoption attempt: the transfer bumps `epoch`, then quiesce fails and
    // it aborts before the ownership flip. Nothing about the pane changed.
    await #expect(throws: PaneError.inputNotQuiesced(paneId: pane.paneId)) {
        _ = try await coordinator.createLocationPane(
            sessionId: UUID(),
            backend: backend,
            isOwnerSessionAlive: { _ in false }
        )
    }

    await gate.release()
    try await inFlight.value

    // The command reached the device, and ownership never moved, so the
    // claim must stand.
    let state = try await coordinator.locationState(
        paneId: pane.paneId,
        as: .session(owner, incarnation: nil)
    )
    #expect(state.location == .scenario(name: "City Run"))
}

/// A shutdown keeps the *same* `Record` while clearing its backend and
/// dropping the claim, so an identity check alone still passes. Without
/// the `locationEpoch` check the response would pair a now-absent claim
/// with trips read from the retired backend, offering the user scenarios
/// that can no longer be applied.
@Test("scenarios enumerated by a retired backend are discarded")
func enumerationRacingShutdownIsDiscarded() async throws {
    let enumerationGate = LocationGate()
    let backend = ParkingLocationBackend(gate: LocationGate(), enumerationGate: enumerationGate)
    let coordinator = PaneCoordinator()
    let session = UUID()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)

    let read = Task {
        try await coordinator.locationState(paneId: pane.paneId, as: principal)
    }
    while await enumerationGate.entered < 1 { await Task.yield() }

    await coordinator.markPanesShutdown(forUDID: "udid-loc")
    await enumerationGate.release()

    let state = try await read.value
    #expect(state.location == nil)
    #expect(state.scenarios.isEmpty, "trips from a retired backend must not be offered")
}

/// A read must re-authorize after its suspension, not merely re-identify
/// the record. An ownership transfer mutates the *same* `Record`, so a
/// `.session` principal that passed the gate before enumeration would
/// otherwise be answered about a pane that has since moved to another
/// session.
@Test("a read whose pane transfers away is refused, not answered")
func readRacingTransferIsRefused() async throws {
    let enumerationGate = LocationGate()
    let backend = ParkingLocationBackend(gate: LocationGate(), enumerationGate: enumerationGate)
    let coordinator = PaneCoordinator()
    let firstOwner = UUID()
    let pane = try await coordinator.createLocationPane(sessionId: firstOwner, backend: backend)

    let read = Task {
        try await coordinator.locationState(
            paneId: pane.paneId,
            as: .session(firstOwner, incarnation: nil)
        )
    }
    while await enumerationGate.entered < 1 { await Task.yield() }

    _ = try await coordinator.createLocationPane(
        sessionId: UUID(),
        backend: backend,
        isOwnerSessionAlive: { _ in false }
    )
    await enumerationGate.release()

    await #expect(throws: PaneError.notFound(paneId: pane.paneId)) {
        _ = try await read.value
    }
}

// MARK: - Handler validation

/// Coordinates are range-checked in the handler so a caller mistake is
/// `invalidParams`, not an opaque bridge fault.
///
/// No `NaN` row here: JSON has no literal for it and `JSONEncoder`
/// refuses to emit one, so a non-finite coordinate cannot arrive over
/// the wire at all. `SimulatedLocation.defect` still rejects it, since
/// the type is used in-process too, and `SimulatedLocationTests` covers
/// that arm directly.
@Test("the handler rejects an out-of-range coordinate before dispatch", arguments: [
    (91.0, 0.0),
    (-91.0, 0.0),
    (0.0, 181.0),
    (0.0, -181.0)
])
func handlerRejectsBadCoordinates(latitude: Double, longitude: Double) async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let handler = PaneMethods.locationSet(paneCoordinator: coordinator)
    let params = try JSONEncoder().encode(
        PaneLocationSetParams(
            paneId: pane.paneId.uuidString,
            location: .coordinate(latitude: latitude, longitude: longitude)
        )
    )
    await #expect(throws: (any Error).self) { _ = try await handler(params) }
    // Rejected before the backend saw anything.
    #expect(backend.coordinates.isEmpty)
}

@Test("the handler rejects a malformed paneId")
func handlerRejectsMalformedPaneId() async throws {
    let handler = PaneMethods.locationState(paneCoordinator: PaneCoordinator())
    let params = try JSONEncoder().encode(PaneLocationStateParams(paneId: "not-a-uuid"))
    await #expect(throws: (any Error).self) { _ = try await handler(params) }
}

// MARK: - Routes

/// A route is a claim like any other, so the checkmark can follow it.
@Test("a successful route becomes the tracked location")
func routeBecomesTheClaim() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let principal = PaneAccessPrincipal.session(session, incarnation: nil)

    try await coordinator.setLocation(paneId: pane.paneId, as: principal, to: .route(spec: validRoute))
    let after = try await coordinator.locationState(paneId: pane.paneId, as: principal)
    #expect(after.location == .route(spec: validRoute))
}

/// The daemon re-validates what a client sends. The GUI checks a route
/// before framing it so the failure lands next to the row the user
/// clicked, but the daemon does not take that on trust: a hand-rolled
/// frame carrying one waypoint, or a point off the globe, is
/// `invalidParams` and never reaches a backend that would hand a bare
/// `NSArray` to Apple's code.
@Test("the handler rejects a malformed route before dispatch", arguments: [
    // One waypoint: shorter than either backend accepts.
    RouteSpec(mode: .interval(seconds: 1), speed: 20, waypoints: [
        RouteWaypoint(latitude: 0, longitude: 0)
    ]),
    // A position that isn't on Earth.
    RouteSpec(mode: .interval(seconds: 1), speed: 20, waypoints: [
        RouteWaypoint(latitude: 0, longitude: 0),
        RouteWaypoint(latitude: 91, longitude: 0)
    ]),
    // A route that never moves.
    RouteSpec(mode: .interval(seconds: 1), speed: 0, waypoints: [
        RouteWaypoint(latitude: 0, longitude: 0),
        RouteWaypoint(latitude: 1, longitude: 1)
    ]),
    // A cadence that would publish forever or never.
    RouteSpec(mode: .distance(meters: 0), speed: 20, waypoints: [
        RouteWaypoint(latitude: 0, longitude: 0),
        RouteWaypoint(latitude: 1, longitude: 1)
    ])
])
func handlerRejectsMalformedRoutes(spec: RouteSpec) async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    let handler = PaneMethods.locationSet(paneCoordinator: coordinator)
    let params = try JSONEncoder().encode(
        PaneLocationSetParams(paneId: pane.paneId.uuidString, location: .route(spec: spec))
    )
    // The *code* matters, not just that it threw. Validation runs before
    // the principal check, so asserting `invalidParams` is what proves
    // the route was rejected on its merits rather than for want of an
    // authenticated caller, which every handler call in a unit test
    // lacks.
    await #expect(throws: (any Error).self) { _ = try await handler(params) }
    #expect(await thrownCode(from: handler, params) == RPCMethodError.invalidParamsCode)
    #expect(backend.routes.isEmpty, "a rejected route reached the backend")
}

/// The RPC error code a handler answers with, or nil if it succeeded or
/// failed some other way.
private func thrownCode(
    from handler: MethodRegistry.Handler,
    _ params: Data
) async -> Int? {
    do {
        _ = try await handler(params)
        return nil
    } catch let error as RPCMethodError {
        return error.code
    } catch {
        return nil
    }
}

/// The waypoint cap is a wire-shape rule, not an arbitrary one: it keeps
/// an oversized file failing with a sentence rather than as a framing
/// fault. A route right at the cap must still be accepted.
@Test("a route at the waypoint cap is accepted, one over is not")
func waypointCapBoundary() async throws {
    func spec(_ count: Int) -> RouteSpec {
        RouteSpec(
            mode: .interval(seconds: 1),
            speed: 20,
            waypoints: (0..<count).map { RouteWaypoint(latitude: Double($0 % 90), longitude: 0) }
        )
    }

    // At the cap: valid, and the whole daemon path carries it. Sent
    // through the coordinator rather than the handler because a unit
    // test has no authenticated dispatch context, and this half is about
    // a route that must *succeed*.
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = LocationMockBackend()
    let pane = try await coordinator.createLocationPane(sessionId: session, backend: backend)
    try await coordinator.setLocation(
        paneId: pane.paneId,
        as: .session(session, incarnation: nil),
        to: .route(spec: spec(RouteSpec.maximumWaypoints))
    )
    #expect(backend.routes.first?.waypoints.count == RouteSpec.maximumWaypoints)

    // One over: rejected by the handler as `invalidParams`, before any
    // principal is required.
    let handler = PaneMethods.locationSet(paneCoordinator: coordinator)
    let params = try JSONEncoder().encode(
        PaneLocationSetParams(
            paneId: pane.paneId.uuidString,
            location: .route(spec: spec(RouteSpec.maximumWaypoints + 1))
        )
    )
    #expect(await thrownCode(from: handler, params) == RPCMethodError.invalidParamsCode)
    #expect(backend.routes.count == 1)
}
