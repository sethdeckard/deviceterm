// SPDX-License-Identifier: GPL-3.0-or-later
//
// FakeDaemonClient: a test double conforming to all four daemon
// role protocols. It records every call and returns scripted
// results, so controllers and view models can be exercised without
// a live daemon. The shared fake for the App tests.

@testable import App
import CoreGraphics
import DaemonProtocol
import Foundation

@MainActor
final class FakeDaemonClient: SessionControlling, DeviceControlling,
    PhysicalDeviceControlling, PaneControlling, PaneSubscribing,
    PaneAccessibilityControlling, PaneLocationControlling,
    TerminalBinding, ReconnectObserving,
    OrchestratorGranting, DisplayTitlePublishing {
    // MARK: - Recorded calls

    struct BindTerminalCall: Equatable {
        let sessionId: String
        let foregroundPid: Int32
        let ttyName: String
    }
    struct GrantOrchestratorCall: Equatable {
        let sessionIds: [UUID]
        let revision: Int
    }
    struct CreateSessionCall: Equatable {
        let label: String?
        let name: String?
        let role: SessionRole
        let initialPrivate: Bool
    }
    struct CloseSessionCall: Equatable {
        let sessionId: String
        let capability: String
        let mode: PaneCloseMode
    }
    struct DeviceListCall: Equatable { let scope: DeviceListScope }
    struct BootDeviceCall: Equatable {
        let udid: String
        let sessionId: String?
        let capability: String?
    }
    struct AttachDeviceCall: Equatable {
        let sessionId: String
        let capability: String
        let udid: String
    }
    struct AttachPhysicalDeviceCall: Equatable {
        let deviceId: String
        let sessionId: String
    }
    struct ClosePaneCall: Equatable {
        let paneId: String
        let mode: PaneCloseMode
    }
    struct SetPrivateBatchCall: Equatable {
        let sessionIds: [String]
        let isPrivate: Bool
        let revision: Int
    }
    struct PrivacySnapshotCall: Equatable {
        let sessionIds: [String]
        let revision: Int
    }
    struct CrownCall: Equatable {
        let paneId: String
        let delta: Double
        let durationMs: Int
    }
    struct ButtonCall: Equatable {
        let paneId: String
        let button: HardwareButton
    }
    struct RotateCall: Equatable {
        let paneId: String
        let orientation: Orientation
    }
    struct PaneAxPointCall: Equatable {
        let paneId: String
        let x: Double
        let y: Double
    }
    struct LocationSetCall: Equatable {
        let paneId: String
        let location: SimulatedLocation
    }
    struct MultitouchCall: Equatable {
        let paneId: String
        let phase: TouchPhase
        let finger1: CGPoint
        let finger2: CGPoint
    }
    struct SwipeCall: Equatable {
        let paneId: String
        let fromX: Double
        let fromY: Double
        let toX: Double
        let toY: Double
        let durationMs: Int
        let holdMs: Int
        let startHoldMs: Int
    }
    struct EdgeSwipeCall: Equatable {
        let paneId: String
        let fromX: Double
        let fromY: Double
        let toX: Double
        let toY: Double
        let edge: Int
        let durationMs: Int
        let holdMs: Int
    }
    struct TouchCall: Equatable {
        let paneId: String
        let x: Double
        let y: Double
        let phase: TouchPhase
    }
    struct EdgeTouchCall: Equatable {
        let paneId: String
        let x: Double
        let y: Double
        let phase: TouchPhase
        let edge: Int
    }
    struct KeyCall: Equatable {
        let paneId: String
        let keyCode: UInt32
        let down: Bool
    }

    private(set) var bindTerminalCalls: [BindTerminalCall] = []
    private(set) var grantOrchestratorCalls: [GrantOrchestratorCall] = []
    /// Client-internal monotonic revision the fake stamps per grant send,
    /// mirroring `DaemonClient.grantRevision`, so a test can assert the
    /// recorded revisions strictly increase across issues/reissues.
    private var grantRevisionCounter = 0
    /// Scripted per-call outcomes (FIFO). An `Error` throws; a `Bool` sets
    /// `applied`. Empty → `applied: true`.
    var grantOrchestratorFailures: [Error?] = []
    var grantOrchestratorApplied: [Bool] = []
    private(set) var reconnectObservers: [ReconnectObserverToken: @MainActor () -> Void] = [:]
    private(set) var createSessionCalls: [CreateSessionCall] = []
    private(set) var closeSessionCalls: [CloseSessionCall] = []
    private(set) var deviceListCalls: [DeviceListCall] = []
    private(set) var bootDeviceCalls: [BootDeviceCall] = []
    private(set) var shutdownDeviceCalls: [String] = []
    private(set) var attachDeviceCalls: [AttachDeviceCall] = []
    private(set) var closePaneCalls: [ClosePaneCall] = []
    private(set) var subscribePaneCalls: [String] = []
    /// Errors to throw from `subscribePane`, consumed one per call from the
    /// front. A `nil` entry (or an empty queue) yields a normal stream. Lets
    /// a test script "transient transport fail, then succeed" or a terminal
    /// daemon failure.
    var subscribePaneFailures: [Error?] = []
    private(set) var setPrivateBatchCalls: [SetPrivateBatchCall] = []
    /// Every `session.restoreBatch` the client sent, in order: one array of
    /// `RestoredSession`s per call. A reconnect test asserts the inventory the
    /// coordinator pushed (and that it landed before terminal rebinds).
    private(set) var restoreBatchCalls: [[RestoredSession]] = []
    /// Every `session.setDisplayTitle` push as `(sessionId, title)`, in order.
    /// A nil title is the clear, and is recorded as such.
    private(set) var setDisplayTitleCalls: [(sessionId: String, title: String?)] = []
    /// Errors to throw from `setDisplayTitle`, consumed one per call from the
    /// front. A `nil` entry (or an empty queue) succeeds.
    var setDisplayTitleFailures: [Error?] = []
    private(set) var crownCalls: [CrownCall] = []
    private(set) var buttonCalls: [ButtonCall] = []
    private(set) var rotateCalls: [RotateCall] = []
    private(set) var paneAxPointCalls: [PaneAxPointCall] = []
    private(set) var locationSetCalls: [LocationSetCall] = []
    /// Every `pane.location.state` call's paneId, in order.
    private(set) var locationStateCalls: [String] = []
    private(set) var multitouchCalls: [MultitouchCall] = []
    private(set) var swipeCalls: [SwipeCall] = []
    private(set) var edgeSwipeCalls: [EdgeSwipeCall] = []
    private(set) var touchCalls: [TouchCall] = []
    private(set) var edgeTouchCalls: [EdgeTouchCall] = []
    /// Every `pane.input.*` call as `(method, paneId)`, in order.
    private(set) var paneInputCalls: [(method: RPCMethod, paneId: String)] = []
    private(set) var keyCalls: [KeyCall] = []

    // MARK: - Scripted results

    var sessionToReturn = SessionCreateResponse(sessionId: "S", capability: "C")
    /// Optional per-call session responses. When non-empty, each
    /// `createSession` call pops the head; once exhausted, falls
    /// through to `sessionToReturn`. Multi-terminal tests use this to
    /// distinguish the primary terminal's session from a second one
    /// minted by `openTerminalPane`.
    var sessionSequence: [SessionCreateResponse] = []
    var deviceListResult: [DeviceListEntry] = []
    private(set) var physicalDeviceListCallCount = 0
    private(set) var attachPhysicalDeviceCalls: [AttachPhysicalDeviceCall] = []
    var physicalDeviceListResult: [PhysicalDeviceListEntry] = []
    /// When set, `physicalDeviceList` throws this instead of returning:
    /// drives the picker VM's load-failure path.
    var physicalDeviceListError: Error?
    var attachResult = PaneCreateResponse(
        paneId: "P",
        scale: nil
    )
    /// When set, `attachDevice` throws this instead of returning.
    var attachError: Error?
    /// Errors to throw from `setPrivateBatch`, consumed one per call from
    /// the front. A `nil` entry (or an empty queue) yields a successful
    /// reply. Lets a transition test script "transport-fail then ack"
    /// (indeterminate retry) or a definite daemon rejection.
    var setPrivateBatchFailures: [Error?] = []
    /// Scripted `applied` flags for `setPrivateBatch` replies, consumed one
    /// per (non-throwing) call from the front; an empty queue yields
    /// `applied: true`. Queue `false` to simulate a stale write that lost
    /// the daemon-side `(epoch, revision)` race.
    var setPrivateBatchApplied: [Bool] = []
    private(set) var privacySnapshotCalls: [PrivacySnapshotCall] = []
    /// `fenced` flag returned by `privacySnapshot` (default true).
    var privacySnapshotFenced = true
    /// Per-session snapshot state; sessions not listed default to
    /// `.publicState`. Lets a reconciliation test script mixed / missing /
    /// private snapshots.
    var privacySnapshotStates: [String: SessionPrivacyMembership] = [:]
    /// Errors thrown by `privacySnapshot`, one per call from the front (a
    /// `nil` entry or empty queue = success). Models a lost authoritative read
    /// so the reconcile-retry can be exercised.
    var privacySnapshotFailures: [Error?] = []
    /// Scripted `fenced` flags, one per call from the front; empty queue falls
    /// back to `privacySnapshotFenced`. Lets a test drive "unfenced then
    /// fenced" so the retry converges.
    var privacySnapshotFencedQueue: [Bool] = []
    /// Confirmed daemon privacy, mutated by applied `setPrivateBatch` calls
    /// so `privacySnapshot` returns a realistic state without per-test setup.
    private var fakePrivateSessions: Set<String> = []
    /// Per-session last-applied ordering revision (epoch is stable in the
    /// fake's single connection), so the fake models the daemon's fence: a
    /// `setPrivateBatch` whose revision doesn't dominate returns
    /// `applied: false`, and a `privacySnapshot` advances it. Bypassed when a
    /// test explicitly scripts `setPrivateBatchApplied` / the fenced queue.
    private var fakeSessionKey: [String: Int] = [:]
    private var privacySnapshotGateArmed = false
    private var privacySnapshotContinuations: [CheckedContinuation<Void, Never>] = []
    /// Scripted return value for `paneAxPoint` calls. Default
    /// `"role · label"` so chrome AX-inspector tests have something to
    /// render in the common happy-case path.
    var paneAxPointResult: String? = "role · label"
    /// What `paneLocationState` returns. A successful `paneLocationSet`
    /// rewrites its `location`, so the fake behaves like the daemon's
    /// set-then-refresh cycle without a test scripting both halves.
    var locationStateResult = PaneLocationStateResult(location: nil, scenarios: [])
    /// When set, `paneLocationSet` throws it instead of recording a new
    /// location.
    var locationSetFailure: Error?
    /// When set, `paneLocationState` throws it.
    var locationStateFailure: Error?
    /// When true, `paneLocationSet` suspends after recording the call
    /// until `releaseLocationSet()`, modelling a daemon that has not
    /// answered yet. Lets a test express "dispatched but not finished".
    var holdLocationSet = false
    private var locationSetWaiters: [CheckedContinuation<Void, Never>] = []

    /// Continuation for the most recent `subscribePane` stream, so a
    /// test can feed `PaneEvent`s and finish it on demand.
    private(set) var lastPaneEventContinuation: AsyncStream<PaneEvent>.Continuation?
    var supportsLiveTouchInput = true
    var supportsMultitouchInput = true

    // MARK: - Awaitable attach barrier

    /// When armed, `attachDevice` / `attachPhysicalDevice` suspend until
    /// `releaseAttach()`, so a test can observe in-flight pending state
    /// and the cancel/teardown race. Off by default: existing tests see
    /// an instant attach.
    private var attachGateArmed = false
    private var attachContinuations: [CheckedContinuation<Void, Never>] = []
    /// Number of attach calls currently suspended on the barrier.
    private(set) var attachesWaiting = 0
    /// Separate barrier for `closeSession` so a test can suspend a tab
    /// teardown mid-flight (between cancelling the attach task and
    /// removing the tab) and reproduce the attach-resumes-during-close
    /// race.
    private var closeSessionGateArmed = false
    private var closeSessionSkipFirst = false
    private var closeSessionFirstSkipped = false
    private var closeSessionContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var closeSessionsWaiting = 0
    /// Barrier for `setPrivateBatch` so a privacy-transition test can
    /// observe the fail-closed pending state before the daemon acks.
    private var setPrivateBatchGateArmed = false
    private var setPrivateBatchFirstOnly = false
    private var setPrivateBatchFirstParked = false
    private var setPrivateBatchContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var setPrivateBatchesWaiting = 0
    /// Barrier for `createSession` so a test can suspend a terminal's
    /// session mint mid-flight and land a privacy transition's commit
    /// during that await (the create-during-transition race).
    private var createSessionGateArmed = false
    private var createSessionContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var createSessionsWaiting = 0

    func armAttachBarrier() { attachGateArmed = true }

    /// Resume every suspended attach and disarm so they run to
    /// completion. Idempotent; safe to call with nothing waiting.
    func releaseAttach() {
        attachGateArmed = false
        let continuations = attachContinuations
        attachContinuations.removeAll()
        attachesWaiting = 0
        for continuation in continuations { continuation.resume() }
    }

    private func awaitAttachGate() async {
        guard attachGateArmed else { return }
        attachesWaiting += 1
        await withCheckedContinuation { attachContinuations.append($0) }
    }

    func armCloseSessionBarrier() {
        closeSessionGateArmed = true
        closeSessionSkipFirst = false
        closeSessionFirstSkipped = false
    }

    /// Let the FIRST `closeSession` through, then stall the rest, so a
    /// multi-tab close can complete one tab's teardown while a later tab's
    /// teardown lingers.
    func armCloseSessionBarrierExceptFirst() {
        closeSessionGateArmed = true
        closeSessionSkipFirst = true
        closeSessionFirstSkipped = false
    }

    func releaseCloseSession() {
        closeSessionGateArmed = false
        closeSessionSkipFirst = false
        closeSessionFirstSkipped = false
        let continuations = closeSessionContinuations
        closeSessionContinuations.removeAll()
        closeSessionsWaiting = 0
        for continuation in continuations { continuation.resume() }
    }

    private func awaitCloseSessionGate() async {
        guard closeSessionGateArmed else { return }
        if closeSessionSkipFirst, !closeSessionFirstSkipped {
            closeSessionFirstSkipped = true
            return
        }
        closeSessionsWaiting += 1
        await withCheckedContinuation { closeSessionContinuations.append($0) }
    }

    func armCreateSessionBarrier() { createSessionGateArmed = true }

    func releaseCreateSession() {
        createSessionGateArmed = false
        let continuations = createSessionContinuations
        createSessionContinuations.removeAll()
        createSessionsWaiting = 0
        for continuation in continuations { continuation.resume() }
    }

    private func awaitCreateSessionGate() async {
        guard createSessionGateArmed else { return }
        createSessionsWaiting += 1
        await withCheckedContinuation { createSessionContinuations.append($0) }
    }

    func armSetPrivateBatchBarrier() {
        setPrivateBatchGateArmed = true
        setPrivateBatchFirstOnly = false
        setPrivateBatchFirstParked = false
    }

    /// Stall only the *first* `setPrivateBatch` call; later calls pass
    /// through immediately. Models a permanently stalled predecessor while
    /// a successor completes. The successor must still be able to commit.
    func armSetPrivateBatchStallFirstOnly() {
        setPrivateBatchGateArmed = true
        setPrivateBatchFirstOnly = true
        setPrivateBatchFirstParked = false
    }

    func releaseSetPrivateBatch() {
        setPrivateBatchGateArmed = false
        setPrivateBatchFirstOnly = false
        setPrivateBatchFirstParked = false
        let continuations = setPrivateBatchContinuations
        setPrivateBatchContinuations.removeAll()
        setPrivateBatchesWaiting = 0
        for continuation in continuations { continuation.resume() }
    }

    /// Release only the FIRST parked `setPrivateBatch` continuation, leaving
    /// the gate armed so later sends stay parked. Models an older send's
    /// reply landing while a newer one is still in flight.
    func releaseFirstSetPrivateBatch() {
        guard !setPrivateBatchContinuations.isEmpty else { return }
        let first = setPrivateBatchContinuations.removeFirst()
        setPrivateBatchesWaiting = max(0, setPrivateBatchesWaiting - 1)
        first.resume()
    }

    private func awaitSetPrivateBatchGate() async {
        guard setPrivateBatchGateArmed else { return }
        if setPrivateBatchFirstOnly {
            if setPrivateBatchFirstParked { return }
            setPrivateBatchFirstParked = true
        }
        setPrivateBatchesWaiting += 1
        await withCheckedContinuation { setPrivateBatchContinuations.append($0) }
    }

    // MARK: - SessionControlling

    func createSession(
        label: String?,
        name: String?,
        role: SessionRole,
        initialPrivate: Bool
    ) async -> SessionCreateResponse {
        createSessionCalls.append(
            .init(label: label, name: name, role: role, initialPrivate: initialPrivate)
        )
        await awaitCreateSessionGate()
        if !sessionSequence.isEmpty {
            return sessionSequence.removeFirst()
        }
        return sessionToReturn
    }

    func closeSession(
        sessionId: String,
        capability: String,
        mode: PaneCloseMode
    ) async {
        closeSessionCalls.append(
            .init(sessionId: sessionId, capability: capability, mode: mode)
        )
        await awaitCloseSessionGate()
    }

    func setPrivateBatch(
        sessionIds: [String],
        isPrivate: Bool,
        revision: Int
    ) async throws -> SessionSetPrivateBatchResult {
        setPrivateBatchCalls.append(
            .init(sessionIds: sessionIds, isPrivate: isPrivate, revision: revision)
        )
        await awaitSetPrivateBatchGate()
        if !setPrivateBatchFailures.isEmpty, let error = setPrivateBatchFailures.removeFirst() {
            throw error
        }
        // `applied` defaults to true (the daemon committed); a test queues
        // `false` in `setPrivateBatchApplied` to simulate a stale write that
        // lost the `(epoch, revision)` race.
        // `applied`: a scripted flag if queued, else the daemon fence: apply
        // only when this revision dominates every target session's last key.
        let applied: Bool
        if setPrivateBatchApplied.isEmpty {
            applied = sessionIds.allSatisfy { revision > (fakeSessionKey[$0] ?? 0) }
        } else {
            applied = setPrivateBatchApplied.removeFirst()
        }
        // Track confirmed state + advance keys so `privacySnapshot` reflects
        // reality (an applied batch mutates + advances; a stale one doesn't).
        if applied {
            for id in sessionIds {
                fakeSessionKey[id] = revision
                if isPrivate { fakePrivateSessions.insert(id) } else { fakePrivateSessions.remove(id) }
            }
        }
        return SessionSetPrivateBatchResult(
            applied: applied,
            revision: revision,
            isPrivate: isPrivate
        )
    }

    func setDisplayTitle(sessionId: String, title: String?) async throws {
        await Task.yield()
        setDisplayTitleCalls.append((sessionId: sessionId, title: title))
        if !setDisplayTitleFailures.isEmpty, let error = setDisplayTitleFailures.removeFirst() {
            throw error
        }
    }

    func restoreBatch(sessions: [RestoredSession]) async -> SessionRestoreBatchResult {
        await Task.yield()
        restoreBatchCalls.append(sessions)
        return SessionRestoreBatchResult(
            restoredCount: sessions.count,
            sessionIds: sessions.map(\.sessionId)
        )
    }

    func privacySnapshot(
        sessionIds: [String],
        revision: Int
    ) async throws -> SessionPrivacySnapshotResult {
        privacySnapshotCalls.append(.init(sessionIds: sessionIds, revision: revision))
        // Capture fenced + states at CALL time, BEFORE the barrier, so a
        // *delayed* response reflects the daemon state when the snapshot was
        // taken, not when released. That's what lets a test simulate a reply
        // that arrives after a newer write has since committed. A test can
        // override any session via `privacySnapshotStates` (mixed / missing /
        // …); otherwise it reflects the tracked applied state.
        // `fenced`: a scripted flag if queued, else the daemon fence:
        // fenced only when this revision dominates every session's last key.
        let fenced: Bool
        if privacySnapshotFencedQueue.isEmpty {
            fenced = privacySnapshotFenced
                && sessionIds.allSatisfy { revision > (fakeSessionKey[$0] ?? 0) }
        } else {
            fenced = privacySnapshotFencedQueue.removeFirst()
        }
        let entries = sessionIds.map { id -> SessionPrivacyEntry in
            let state = privacySnapshotStates[id]
                ?? (fakePrivateSessions.contains(id) ? .privateState : .publicState)
            return SessionPrivacyEntry(sessionId: id, state: state)
        }
        // Fencing advances the key (at capture/daemon-processing time, before
        // the reply delay), so a delayed older write subsequently loses.
        if fenced {
            for id in sessionIds { fakeSessionKey[id] = revision }
        }
        await awaitPrivacySnapshotGate()
        if !privacySnapshotFailures.isEmpty, let error = privacySnapshotFailures.removeFirst() {
            throw error
        }
        return SessionPrivacySnapshotResult(
            fenced: fenced,
            revision: revision,
            sessions: entries
        )
    }

    func armPrivacySnapshotBarrier() { privacySnapshotGateArmed = true }

    func releasePrivacySnapshot() {
        privacySnapshotGateArmed = false
        let continuations = privacySnapshotContinuations
        privacySnapshotContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func awaitPrivacySnapshotGate() async {
        guard privacySnapshotGateArmed else { return }
        await withCheckedContinuation { privacySnapshotContinuations.append($0) }
    }

    // MARK: - DeviceControlling

    func deviceList(scope: DeviceListScope) -> [DeviceListEntry] {
        deviceListCalls.append(.init(scope: scope))
        return deviceListResult
    }

    func bootDevice(
        udid: String,
        sessionId: String?,
        capability: String?
    ) {
        bootDeviceCalls.append(
            .init(udid: udid, sessionId: sessionId, capability: capability)
        )
    }

    func shutdownDevice(udid: String) {
        shutdownDeviceCalls.append(udid)
    }

    func attachDevice(
        sessionId: String,
        capability: String,
        udid: String
    ) async throws -> PaneCreateResponse {
        attachDeviceCalls.append(
            .init(sessionId: sessionId, capability: capability, udid: udid)
        )
        await awaitAttachGate()
        if let attachError { throw attachError }
        return attachResult
    }

    // MARK: - PhysicalDeviceControlling

    func physicalDeviceList() throws -> [PhysicalDeviceListEntry] {
        physicalDeviceListCallCount += 1
        if let physicalDeviceListError {
            throw physicalDeviceListError
        }
        return physicalDeviceListResult
    }

    func attachPhysicalDevice(
        deviceId: String,
        sessionId: String
    ) async throws -> PaneCreateResponse {
        attachPhysicalDeviceCalls.append(.init(deviceId: deviceId, sessionId: sessionId))
        await awaitAttachGate()
        if let attachError { throw attachError }
        return attachResult
    }

    // MARK: - PaneControlling

    func closePane(paneId: String, mode: PaneCloseMode) {
        closePaneCalls.append(.init(paneId: paneId, mode: mode))
    }

    func paneInputTap(paneId: String, x: Double, y: Double) {
        paneInputCalls.append((.paneInputTap, paneId))
    }

    func paneInputTouch(
        paneId: String,
        x: Double,
        y: Double,
        phase: TouchPhase
    ) {
        touchCalls.append(.init(paneId: paneId, x: x, y: y, phase: phase))
        paneInputCalls.append((.paneInputTouch, paneId))
    }

    func paneInputEdgeTouch(
        paneId: String,
        x: Double,
        y: Double,
        phase: TouchPhase,
        edge: Int
    ) {
        edgeTouchCalls.append(.init(paneId: paneId, x: x, y: y, phase: phase, edge: edge))
        paneInputCalls.append((.paneInputEdgeTouch, paneId))
    }

    func paneInputSwipe(
        paneId: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int,
        holdMs: Int,
        startHoldMs: Int
    ) {
        swipeCalls.append(.init(
            paneId: paneId,
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            durationMs: durationMs,
            holdMs: holdMs,
            startHoldMs: startHoldMs
        ))
        paneInputCalls.append((.paneInputSwipe, paneId))
    }

    func paneInputEdgeSwipe(
        paneId: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        edge: Int,
        durationMs: Int,
        holdMs: Int
    ) {
        edgeSwipeCalls.append(.init(
            paneId: paneId,
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            edge: edge,
            durationMs: durationMs,
            holdMs: holdMs
        ))
        paneInputCalls.append((.paneInputEdgeSwipe, paneId))
    }

    func paneInputLongPress(
        paneId: String,
        x: Double,
        y: Double,
        durationMs: Int
    ) {
        paneInputCalls.append((.paneInputLongPress, paneId))
    }

    func paneInputKey(paneId: String, keyCode: UInt32, down: Bool) {
        paneInputCalls.append((.paneInputKey, paneId))
        keyCalls.append(KeyCall(paneId: paneId, keyCode: keyCode, down: down))
    }

    func paneInputButton(paneId: String, button: HardwareButton) {
        paneInputCalls.append((.paneInputButton, paneId))
        buttonCalls.append(ButtonCall(paneId: paneId, button: button))
    }

    func paneInputPinch(
        paneId: String,
        fromF1X: Double,
        fromF1Y: Double,
        fromF2X: Double,
        fromF2Y: Double,
        toF1X: Double,
        toF1Y: Double,
        toF2X: Double,
        toF2Y: Double,
        durationMs: Int
    ) {
        paneInputCalls.append((.paneInputPinch, paneId))
    }

    func paneInputMultitouch(
        paneId: String,
        phase: TouchPhase,
        finger1: CGPoint,
        finger2: CGPoint
    ) {
        paneInputCalls.append((.paneInputMultitouch, paneId))
        multitouchCalls.append(MultitouchCall(
            paneId: paneId,
            phase: phase,
            finger1: finger1,
            finger2: finger2
        ))
    }

    func paneInputText(paneId: String, text: String) {
        paneInputCalls.append((.paneInputText, paneId))
    }

    func paneInputRotate(paneId: String, orientation: Orientation) {
        paneInputCalls.append((.paneInputRotate, paneId))
        rotateCalls.append(RotateCall(paneId: paneId, orientation: orientation))
    }

    func paneInputCrown(paneId: String, delta: Double, durationMs: Int) {
        paneInputCalls.append((.paneInputCrown, paneId))
        crownCalls.append(
            CrownCall(
            paneId: paneId,
            delta: delta,
            durationMs: durationMs
        )
            )
    }

    // MARK: - PaneSubscribing

    func subscribePane(paneId: String) throws -> AsyncStream<PaneEvent> {
        subscribePaneCalls.append(paneId)
        if !subscribePaneFailures.isEmpty, let error = subscribePaneFailures.removeFirst() {
            throw error
        }
        let (stream, continuation) = AsyncStream.makeStream(of: PaneEvent.self)
        lastPaneEventContinuation = continuation
        return stream
    }

    // MARK: - PaneAccessibilityControlling

    /// Matches the protocol shape (`async throws`). The `Task.sleep(0)`
    /// is a meaningful await: it forces the caller onto a fresh
    /// continuation, mirroring a real round-trip's await boundary so
    /// tests that depend on the caller yielding (e.g. the throttle
    /// gate clearing `axQueryInFlight` after the daemon replies) don't
    /// pass by accident on a sync return path.
    func paneAxPoint(paneId: String, x: Double, y: Double) async throws -> String? {
        paneAxPointCalls.append(.init(paneId: paneId, x: x, y: y))
        try await Task.sleep(nanoseconds: 0)
        return paneAxPointResult
    }

    // MARK: - PaneLocationControlling

    /// Let every held `paneLocationSet` finish.
    func releaseLocationSet() {
        holdLocationSet = false
        let resuming = locationSetWaiters
        locationSetWaiters = []
        for waiter in resuming { waiter.resume() }
    }

    func paneLocationSet(paneId: String, location: SimulatedLocation) async throws {
        locationSetCalls.append(.init(paneId: paneId, location: location))
        try await Task.sleep(nanoseconds: 0)  // mirror a real round-trip's await boundary
        // Hold the call *after* it has been recorded as dispatched, so a
        // test can act while the daemon is still thinking about it.
        if holdLocationSet {
            await withCheckedContinuation { locationSetWaiters.append($0) }
        }
        if let error = locationSetFailure { throw error }
        // Model the daemon: the tracked value moves only on success, so a
        // scripted failure leaves the state a refresh would report unchanged.
        locationStateResult = PaneLocationStateResult(
            location: location,
            scenarios: locationStateResult.scenarios
        )
    }

    func paneLocationState(paneId: String) async throws -> PaneLocationStateResult {
        locationStateCalls.append(paneId)
        try await Task.sleep(nanoseconds: 0)
        if let error = locationStateFailure { throw error }
        return locationStateResult
    }

    // MARK: - TerminalBinding

    func bindTerminal(sessionId: String, foregroundPid: Int32, ttyName: String) async throws {
        bindTerminalCalls.append(
            BindTerminalCall(sessionId: sessionId, foregroundPid: foregroundPid, ttyName: ttyName)
        )
        try await Task.sleep(nanoseconds: 0)  // mirror a real round-trip's await boundary
    }

    // MARK: - OrchestratorGranting

    @discardableResult
    func grantOrchestrator(sessionIds: [UUID]) async throws -> OrchestratorGrantResult {
        grantRevisionCounter += 1
        grantOrchestratorCalls.append(
            GrantOrchestratorCall(sessionIds: sessionIds, revision: grantRevisionCounter)
        )
        try await Task.sleep(nanoseconds: 0)  // mirror a real round-trip's await boundary
        if !grantOrchestratorFailures.isEmpty, let failure = grantOrchestratorFailures.removeFirst() {
            throw failure
        }
        let applied = grantOrchestratorApplied.isEmpty ? true : grantOrchestratorApplied.removeFirst()
        return OrchestratorGrantResult(applied: applied)
    }

    // MARK: - ReconnectObserving

    func addReconnectObserver(_ handler: @escaping @MainActor () -> Void) -> ReconnectObserverToken {
        let token = ReconnectObserverToken(id: UUID())
        reconnectObservers[token] = handler
        return token
    }

    func removeReconnectObserver(_ token: ReconnectObserverToken) {
        reconnectObservers[token] = nil
    }

    /// Test hook: fire every registered reconnect observer.
    func simulateReconnect() {
        for observer in reconnectObservers.values { observer() }
    }
}
