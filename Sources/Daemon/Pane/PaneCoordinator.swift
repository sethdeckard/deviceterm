// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneCoordinator: the daemon's actor for pane lifecycle.
//
// A *pane* is the GUI's window into a simulator's display. The
// daemon owns a `SimDisplayHandle` for the pane; CoreSimulator
// delivers `IOSurfaceID`s on its own queue and we fan each out to
// every subscriber as a `surface.changed` event.
//
// State machine:
//
//     booting ──first IOSurface──▶ rendering
//                                       │
//                                  shutdown / failed
//
// Subscribers receive `state.changed` on transition and
// `surface.changed` on every fresh IOSurface. `pane.subscribe` is a
// streaming method whose events share the original request's id.
//
// `SimDisplayHandle` is non-Sendable; we hold it inside an
// `@unchecked Sendable` record class. Only this actor mutates the
// records, and the bridge's callback hops back into the actor
// before touching state.

import CoreSimulatorBridge
import DaemonProtocol
import Foundation
import IOSurface
import os
import SurfaceTrace

// The device a pane mirrors is identified by `PaneTarget` (a shared
// DaemonProtocol enum). What *drives* the pane (frames + input) is a
// `DeviceBackend`. A sim pane carries `.sim(udid:)` + a
// `SimDeviceBackend`; a physical-device pane carries `.device(deviceId:)`
// + its own backend, with no change to this coordinator.

// PaneLifecycle and PaneCloseMode are shared wire enums in
// DaemonProtocol (Sources/DaemonProtocol/); visible here via the module
// re-export.

/// Diagnostics for the location surface. File-scope so the actor's
/// static helper can reach it without threading a logger through.
private let locationLog = Logger(subsystem: "com.deviceterm.daemon", category: "location")

public actor PaneCoordinator {
    // HardwareButton (`pane.input.button`) and Orientation
    // (`pane.input.rotate`) are shared wire enums in DaemonProtocol; the
    // daemon-only `bridgeValue` mappings to the CoreSimulatorBridge C
    // enums live in HardwareButton+Bridge.swift / Orientation+Bridge.swift.

    /// One subscription on a pane record. Beyond the JSON `PaneEvent`
    /// continuation it carries the authorizing `principal` and, for an
    /// XPC subscriber, the surface-lane `subscriptionToken`, its
    /// registering `connectionId`, and the `lifecycle` box. Together they
    /// let an ownership transfer revoke a subscription *completely*:
    /// synchronously finish the continuation and drop the record (the
    /// entire teardown for a UDS subscriber), and for an XPC subscriber
    /// additionally fire the lifecycle drain and unregister its surface
    /// token so the pool hold and side-band hook are released. UDS
    /// subscribers carry a nil token/connectionId/lifecycle (UDS vends no
    /// surface lane).
    struct Subscriber {
        let continuation: AsyncStream<PaneEvent>.Continuation
        let principal: PaneAccessPrincipal
        let subscriptionToken: UUID?
        let connectionId: UInt64?
        let lifecycle: SubscriptionLifecycle?
    }

    /// One-shot completion state that chains a pane's operations of one
    /// kind in request order. Shared by the rotation and location chains;
    /// each `Record` keeps a separate tail per kind, so the two never
    /// block each other.
    ///
    /// A plain holder: its `done`/`waiter` are read and written **only**
    /// through the coordinator's actor-isolated `awaitChainLink` /
    /// `signalChainLink`, so the `done` check and the continuation
    /// registration happen with no suspension between them and a signal can't
    /// slip in and drop the wakeup. The `@unchecked Sendable` is for storage in
    /// the actor-isolated `Record`; there is no cross-thread access. A single
    /// waiter suffices: each chain is linear (an operation awaits exactly its
    /// immediate predecessor).
    private final class SerialChainLink: @unchecked Sendable {
        var done = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    /// Per-pane mutable state. Class-backed because the record
    /// holds non-Sendable CoreSimulator bridge handles; only the
    /// actor mutates it, so the `@unchecked Sendable` is safe.
    private final class Record: @unchecked Sendable {
        let id: UUID
        /// Owning session. Mutable so cross-session `createSim`
        /// adoption (orphan recovery after a GUI crash leaves the
        /// daemon holding the pane; the new GUI calls
        /// `device.attach` with a fresh recovery session) can
        /// transfer ownership without tearing down + re-acquiring
        /// the bridge handles. See `createSim`'s cross-session
        /// branch.
        var sessionId: UUID
        /// The session cohort permitted to drive this pane, or nil for a pane
        /// that never received one.
        ///
        /// **This, not `sessionId`, is the authorization path.** `sessionId`
        /// remains the record's own owning session: it anchors adoption,
        /// ownership transfer, and the revocation sweep, and it seeds the
        /// compatibility fallback for a pane with no cohort. It is not who is
        /// allowed to drive the pane, and it is not what `ownerSessionId`
        /// reports once a cohort exists.
        ///
        /// Nil and "names a cohort nobody can find" are deliberately different
        /// answers: see `authorize`.
        var cohortId: UUID?
        /// Identifies THIS admission of the record, so a close issued against
        /// one admission can't retire a later one. Advanced by a fresh create,
        /// a revisioned same-owner re-attach, and an ownership transfer. Deliberately not the session incarnation
        /// (unchanged by a same-owner re-attach, so it can't tell two
        /// admissions apart) and not `epoch` (advanced by speculative work
        /// that may abort, so a legitimate close would be refused).
        var attachment: UInt64
        /// The requester-supplied revision of the admission that produced the
        /// current `attachment`, or nil when that admission carried none (the
        /// CLI supplies no revision). Its only job is to reject a stale
        /// re-attach: `attachment` is assigned in the daemon's processing
        /// order, which is NOT the order the requests were issued in, so
        /// without this an out-of-order request would advance the record past
        /// the admission its issuer already acted on.
        var admissionRevision: UInt64?
        let target: PaneTarget
        /// Device family classified at create time (see `DeviceFamily`).
        let family: String
        /// Crockford base32 short_id (6 chars). Daemon-minted at
        /// create time via `ShortID.generate()` with collision retry
        /// against the live pane set; immutable for the pane's
        /// lifetime.
        let shortId: String
        /// Optional human-set name. Nil at create and mutable for the
        /// pane's lifetime once the shipped `pane rename` command is
        /// implemented. Visible on `panes.list` rows.
        var name: String?
        /// Human-readable device type from `SimDeviceType.name`.
        /// Captured at create time so subsequent attach responses
        /// (resurrect, orphan re-adoption) get a consistent value
        /// without re-querying the bridge.
        let deviceType: String?
        /// Wire projection of the backend's capability set, cached at
        /// create time so `panes.list` can still report it after the
        /// pane shuts down (when `backend` is nil).
        let capabilities: PaneCapabilities
        /// What drives this pane's frames + input. A `SimDeviceBackend`
        /// wrapping the CoreSimulator bridge handles for a sim pane; a
        /// physical-device backend otherwise. Held for the pane's life
        /// and cleared (nil) on shutdown: a nil backend is the
        /// canonical "pane is no longer active" signal that
        /// `requireBackend` keys on. Owns the display subscription, HID,
        /// rotation, and (lazily) the accessibility client internally.
        var backend: (any DeviceBackend)?
        /// AXP waits synchronously for replies. Serializing a pane's complete
        /// AX operations here preserves its bridge ordering while letting AX
        /// work on other panes proceed independently.
        let accessibilityWorkQueue: BlockingWorkQueue
        var subscribers: [UUID: Subscriber] = [:]
        var state: PaneLifecycle
        /// Set while an ownership transfer (adoption) is quiescing this
        /// record across its `await`s. The `authorize` gate consults it:
        /// no `.session` principal may reach the pane, and no principal
        /// may enqueue input, until the transfer clears it. Cleared on
        /// every transfer exit (success, abort, or bail). See the transfer
        /// sequence in `createPane`'s adopt branch.
        var transferring: Bool = false
        /// PERSISTENT owner-revoked fence (distinct from the transient
        /// `transferring` marker). Set when a session close revokes this
        /// pane's subscriptions (`revokeSubscriptions(forSession:)`) while
        /// the record's own `sessionId` still names the closed session: the
        /// pane becomes an orphan pending re-adoption. It STAYS set after the
        /// transfer marker clears, so a `.session` `pane.subscribe` that
        /// passed the dispatch scope check while the session was live but
        /// resumed here AFTER the close is refused (`notFound`,
        /// indistinguishable) and mints no surviving subscription. `.guiPeer`
        /// is never gated by it: the GUI keeps rendering the orphan. The
        /// gate reopens only when the record is re-owned by a live session:
        /// an ownership-transfer commit clears it (activating the new owner), or
        /// the owning session re-attaching to its own pane.
        var ownerRevoked: Bool = false
        /// The owner's session INCARNATION this pane was created/adopted under,
        /// or `nil` when the creating caller carried none (a validated-GUI
        /// create/adoption, which is un-pinned). A `.session(id, requestInc)`
        /// principal is admitted only when this is nil, the request's
        /// incarnation is nil, or the two match, so a request authorized under
        /// one incarnation can't reach a pane re-owned by the same UUID at a
        /// *different* incarnation (the reincarnation ABA gate, mirroring
        /// `EventBroker`'s accepted incarnation). Stamped at fresh create,
        /// same-session re-attach, and ownership-transfer commit.
        var acceptedIncarnation: UInt64?
        /// Monotonic ownership/liveness generation. Bumped whenever this
        /// record's owner or terminal state changes (transfer flip,
        /// close, shutdown). A transfer snapshots it before its first
        /// `await` and re-checks after each suspension; a mismatch means a
        /// competing transfer or a close/shutdown raced in, and the
        /// transfer bails rather than mutating a record another actor
        /// entry point already moved.
        var epoch: UInt64 = 0
        /// In-flight `pane.subscribe` setups on this record that have not
        /// yet materialized their surface token, keyed by a per-subscribe
        /// nonce and tagged with the subscribing principal. A transfer
        /// waits only for the **revocable** (`.session`) setups to settle
        /// before it collects tokens to revoke: a permitted `.guiPeer`
        /// setup (presentation spans the transfer) must not be able to
        /// starve it. New `.session` setups can't begin during a transfer
        /// (`authorize` denies them), so the revocable set only shrinks.
        var pendingSubscribeSetup: [UUID: PaneAccessPrincipal] = [:]
        /// A transfer suspended waiting for the last revocable pending
        /// setup to finish. Resumed by `finishPendingSetup` the instant no
        /// `.session` setup remains, an explicit handshake, not a poll.
        var transferSetupWaiter: CheckedContinuation<Void, Never>?
        /// `createPane` callers parked until this record's in-flight
        /// transfer clears the marker (so they never observe the
        /// half-transferred state). Resumed by `clearTransferring`.
        var transferCompletionWaiters: [CheckedContinuation<Void, Never>] = []
        /// Tail of this pane's rotation chain. Rotations serialize
        /// end-to-end through it so they reach the backend, and commit
        /// their control base, in request order: the backend completes
        /// rotations serially, but each `rotate` awaits its completion on
        /// an independent task, and independent continuations aren't
        /// guaranteed to resume in order. Each `rotate` awaits the prior
        /// tail before running and signals its own when done (success,
        /// skip, or throw), so B never reaches the backend or commits its
        /// base before A finishes.
        /// Arbitration for the input verbs that hold digitizer contact.
        /// Created on the pane's first contact verb, so a pane that only ever
        /// rotates or types never builds one.
        var contactLane: ContactLane?
        var rotationTail: SerialChainLink?
        /// The orientation **deviceterm last successfully commanded** on
        /// this pane's device, which a relative rotate advances from. It
        /// starts at `.portrait` because that is where an iOS device
        /// boots, not because anything read the device.
        ///
        /// Written only after the backend reports it performed the
        /// rotation, so a fenced or failed one doesn't compound into the
        /// next relative request. **A backend-reported performed command is
        /// its only writer**, and `presentationOrientation` deliberately does not
        /// correct it: display state is the foreground app's interface
        /// orientation, so a portrait device running a landscape-locked
        /// app would drive this to landscape and mis-target the next
        /// relative rotate.
        ///
        /// Nothing observes it because for a simulator there is nothing to
        /// observe. A simulator has no physical attitude, no sensor, no
        /// ground truth; its device orientation is just whatever rotate
        /// command was last sent, and nothing in CoreSimulator accumulates
        /// that. So a rotation from any other tool leaves this stale and
        /// nothing detects it. A later absolute rotate names its target
        /// directly, so it doesn't depend on this base and records a fresh
        /// one.
        var controlOrientation: Orientation = .portrait
        /// The pane's **presentation** orientation, which is what the
        /// render, the bezel, and the hit-test mapping follow. It describes
        /// the framebuffer where the backend has a display source, and the
        /// last performed command where it hasn't.
        ///
        /// Written by observation where the backend has a display source,
        /// and by a performed rotate where it hasn't. Under observation it
        /// diverges from `controlOrientation` permanently and legitimately:
        /// an orientation-locked app keeps a portrait framebuffer while the
        /// device is turned to landscape. Under the fallback it can only
        /// mirror the command, so an external rotation never reaches it and
        /// a locked app moves it when the framebuffer didn't.
        ///
        /// Starts at `.portrait` for the same reason `controlOrientation`
        /// does, and is corrected by the first seed or observation.
        var presentationOrientation: Orientation = .portrait
        /// Whether display-orientation observation is running for this
        /// pane, so teardown only unregisters what was registered.
        var observingDisplayOrientation = false
        /// Bumped when display observation is torn down, and by nothing
        /// else. The observer's callback captures the value it started
        /// with, so a delivery already in flight past teardown is dropped.
        ///
        /// Deliberately **not** `epoch`. That one also advances on owner
        /// revocation and on both halves of an ownership transfer, none of
        /// which stop the observer or change what the display is doing.
        /// Fencing on it would leave a live observer whose every callback
        /// is rejected, and since the command fallback stands down while
        /// observation is running, the pane's orientation would freeze for
        /// good the first time it changed hands.
        var displayObserverEpoch: UInt64 = 0
        /// Ordered delivery for observed display orientations. The bridge
        /// callback only yields; the drain task funnels them onto the actor
        /// in receive order, the same shape the surface pump uses.
        ///
        /// An unstructured `Task` per callback would not do: independent
        /// tasks have no ordering guarantee, so two quick rotations could
        /// land reversed and leave the pane on the older value for good.
        /// Latest-only buffering is right here because the value is
        /// level-triggered: a skipped intermediate costs nothing, and only
        /// the newest orientation is worth drawing.
        var orientationContinuation: AsyncStream<Orientation>.Continuation?
        var orientationPump: Task<Void, Never>?
        /// Tail of this pane's location chain, serializing location
        /// commands end-to-end for the same reason rotations are chained:
        /// each one suspends on a backend call, and independent
        /// continuations aren't guaranteed to resume in issue order. The
        /// device would end up at the last command it executed while the
        /// tracked claim recorded whichever continuation happened to
        /// resume last, leaving a checkmark on a location the device
        /// isn't at. Separate from `rotationTail` so a slow rotation
        /// doesn't stall a location set or vice versa.
        var locationTail: SerialChainLink?
        /// The simulated GPS position **deviceterm last applied** to this
        /// pane's device, which is not the same thing as the device's
        /// actual simulated position. Neither backend exposes a getter
        /// (CoreSimulator vends only setters plus
        /// `availableLocationScenarios`; `devicectl` has no read verb), so
        /// the daemon can only track its own writes. Something else moving
        /// the device (Simulator.app's Features ▸ Location, a raw
        /// `simctl location` call, an Xcode scheme's default location)
        /// leaves this stale, and nothing can detect that.
        ///
        /// Paired with `locationEpoch`, which advances on exactly the
        /// events listed below, never speculatively.
        ///
        /// **`nil` means "no claim", which is not `.cleared`.** Dropped
        /// back to `nil` wherever the claim stops being credible: at
        /// fresh create (this default, since deviceterm hasn't written
        /// anything and an attached device may already be simulating
        /// something), at the ownership-transfer commit (a new owner
        /// inherits no claim), and on shutdown/failure (also the reboot
        /// path, since a live reboot runs shutdown→boot). Close needs no
        /// reset because it removes the record outright.
        ///
        /// Every one of those is pure bookkeeping: **none sends a
        /// `clear` to the device**, which is why none may record
        /// `.cleared`. A transfer leaves the device untouched, so nothing
        /// about its position follows from it. A shut-down or failed pane
        /// probably did lose its simulation with its state, but
        /// deviceterm neither did that nor can confirm it. `nil` says the
        /// only thing true of all of them: deviceterm doesn't know.
        var simulatedLocation: SimulatedLocation?
        /// Generation for the location claim, advanced **only** where
        /// `simulatedLocation` is actually reset: an ownership-transfer
        /// *commit*, a shutdown, or a failure. A location command
        /// snapshots it at admission and commits only if it still
        /// matches; `locationState` uses it to discard an enumeration
        /// that raced a teardown.
        ///
        /// Deliberately **not** `epoch`. That counter is bumped
        /// speculatively at the *start* of a transfer and is never
        /// restored when one aborts (restoring it would break the
        /// monotonicity its ABA protection depends on). Fencing location
        /// on it would discard a claim whose command reached the device
        /// successfully and whose transfer then aborted, leaving the
        /// owner and backend unchanged but the menu pointing at a
        /// location the device has already left. The location fence
        /// therefore tracks committed changes only.
        var locationEpoch: UInt64 = 0

        /// Whether any in-flight setup is a revocable `.session` one (the
        /// only kind a transfer must wait out).
        var hasPendingSessionSetup: Bool {
            pendingSubscribeSetup.values.contains { if case .session = $0 { return true }; return false }
        }
        /// The currently-bound `PublishedSurface`, if any. Held so a
        /// late-arriving subscriber gets the current frame replayed
        /// immediately + so the XPC-side delivery handle can ship
        /// the bound surface on (re)subscribe. The wrapper owns
        /// retain/use-count lifetime and, for a device frame, the pool
        /// slot's `.daemonCurrent` hold; replacing this field with a
        /// newer one drops the prior wrapper by ARC, releasing its hold.
        var currentSurface: PublishedSurface?
        /// Last sequence number emitted for this pane. Increments
        /// on every fresh surface; `0` means no surface has been
        /// delivered yet. Restarts at 0 on daemon relaunch.
        var lastSequence: UInt64 = 0
        /// Ordered surface pump for this pane. The backend's frame callback
        /// fires from an arbitrary thread and yields each `PublishedSurface`
        /// into `surfaceContinuation` (a `.bufferingNewest(1)` stream). The
        /// detached `surfacePump` asks `PaneCoordinator` to commit sequence and
        /// record state in one non-suspending turn, then awaits side-band
        /// fan-out itself. The first frame re-enters the coordinator once to
        /// fence its lifecycle publication; steady-state frames do not park a
        /// fan-out hop in this actor's mailbox. A superseded frame releases as
        /// soon as a newer one displaces it. Both fields are cleared on
        /// teardown.
        var surfaceContinuation: AsyncStream<PublishedSurface>.Continuation?
        var surfacePump: Task<Void, Never>?
        /// True only while the first-frame `.rendering` event has passed its
        /// lifecycle fence and is awaiting `EventBroker`. Session revocation
        /// waits for it before publishing `.sessionClosed`.
        var surfaceStatePublicationInFlight = false
        var surfaceStatePublicationWaiters: [CheckedContinuation<Void, Never>] = []
        /// The newest terminal transition admitted for this record. A sim
        /// shutdown may supersede an in-flight failure, so only the matching
        /// revision finishes the terminal-publication barrier.
        var terminalPublicationRevision: UInt64 = 0
        var terminalStatePublicationInFlight = false
        var terminalStatePublicationWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            id: UUID,
            sessionId: UUID,
            attachment: UInt64,
            admissionRevision: UInt64?,
            target: PaneTarget,
            state: PaneLifecycle,
            family: String,
            shortId: String,
            name: String?,
            deviceType: String?,
            capabilities: PaneCapabilities
        ) {
            self.id = id
            self.sessionId = sessionId
            self.attachment = attachment
            self.admissionRevision = admissionRevision
            self.target = target
            self.state = state
            self.family = family
            self.shortId = shortId
            self.name = name
            self.deviceType = deviceType
            self.capabilities = capabilities
            self.accessibilityWorkQueue = BlockingWorkQueue(
                label: "com.deviceterm.daemon.pane-ax.\(id)"
            )
        }

        /// Best-effort read of the device's native pixel dimensions.
        /// Returns `(nil, nil)` when the backend is gone (post-shutdown)
        /// or the renderable hasn't bound a surface yet (`displaySize`
        /// is `CGSizeZero` per the bridge contract). The GUI treats nil
        /// as "use family-default sizing" so a startup race doesn't
        /// blank the pane.
        func displayPixelDimensions() -> (Int?, Int?) {
            backend?.pixelDimensions() ?? (nil, nil)
        }

        /// Stop display-orientation observation and finish its pump.
        /// Idempotent.
        func teardownOrientationPump(backend: DeviceBackend?) {
            if observingDisplayOrientation {
                backend?.stopDisplayOrientation()
                observingDisplayOrientation = false
            }
            displayObserverEpoch &+= 1
            orientationContinuation?.finish()
            orientationContinuation = nil
            orientationPump?.cancel()
            orientationPump = nil
        }

        /// Finish the ordered surface pump and stop its drain task.
        /// Called on every teardown path (close, sim shutdown, and a
        /// failed `startFrames`) so no pump outlives the pane.
        /// Idempotent: the fields are cleared after tearing down.
        func teardownSurfacePump() -> Task<Void, Never>? {
            surfaceContinuation?.finish()
            let pump = surfacePump
            pump?.cancel()
            surfaceContinuation = nil
            surfacePump = nil
            return pump
        }
    }

    /// Outcome of an interpolated swipe: the step count actually used
    /// and the clamped duration. Returned so the daemon handler can
    /// surface the `dispatched` field in its `SwipeAck`.
    public struct SwipeOutcome: Sendable, Equatable {
        public let steps: Int
        public let durationMs: Int
    }

    /// What a successful `acquire` hands back to `createPane`: the live
    /// backend plus the device-family / human-readable type the create
    /// response carries. The backend kind (`SimDeviceBackend` vs a
    /// physical one) is the only thing that varies between targets.
    struct AcquiredBackend {
        let backend: any DeviceBackend
        let family: String
        let deviceType: String?
    }

    /// What `inputBackend` resolves for one input operation: the authorized
    /// record, its live backend, and the backend's input generation read in
    /// the same actor step as the ownership gate. Private because `Record`
    /// is.
    private struct AuthorizedInput {
        let record: Record
        let backend: any DeviceBackend
        let generation: UInt64
    }

    /// Immutable work the frame callback commits in one actor turn and hands
    /// back to the pane's ordered pump. JSON subscriber yields stay in that
    /// turn because subscription revocation linearizes on the same actor. The
    /// first-frame lifecycle event is revalidated before publication; every
    /// side-band delivery stays on the pump.
    private struct SurfacePublishWork: Sendable {
        struct StatePublication: Sendable {
            let paneId: UUID
            let epoch: UInt64
            let event: DaemonEvent
            let audience: EventAudience
        }

        let paneId: UUID
        let published: PublishedSurface
        let sequence: UInt64
        let statePublication: StatePublication?
    }

    /// Test-only suspension points for deterministic surface/lifecycle races.
    enum SurfacePumpTestPoint: Sendable, Equatable {
        case beforeCommit
        case beforeStatePublication
        case beforeTerminalPublicationWait
    }

    /// Upper bound on gesture durations (ms) accepted by `swipe`,
    /// `longPress`, and `pinch`. Two reasons: anything past ~60s is
    /// almost certainly a buggy caller (real gestures top out at a
    /// few seconds), and capping at 60s keeps `ms * 1_000_000` well
    /// inside `UInt64` so a malicious or malformed client can't
    /// overflow `Task.sleep(nanoseconds:)` and trap the daemon.
    public static let maxGestureDurationMs: Int = 60_000

    // The swipe-dwell cadence/jitter and the App-Switcher double-press gap
    // live with the gesture logic in `SimInputSynthesis`, their only user.

    private var panes: [UUID: Record] = [:]
    /// Panes removed from `panes` whose teardown or external cleanup is still
    /// in progress. Authorization and `panes.list` ignore these: a retired pane
    /// is gone to every caller. Its own cleanup, and any gesture that captured
    /// it, still reach it by identity.
    ///
    /// Every close passes through here, not only the ones that wait on a
    /// gesture: the target stays reserved until the device is genuinely free.
    private var retiring: [UUID: Record] = [:]
    private var retirementWaiters: [(paneId: UUID, continuation: CheckedContinuation<Void, Never>)] = []
    private var retiringTargetWaiters: [(target: PaneTarget, continuation: CheckedContinuation<Void, Never>)] = []
    /// Pane retirement cleanups in flight. The idle monitor treats a non-zero
    /// count as busy: the owning session is gone from `liveOwnerSessionIds` the
    /// moment the record leaves `panes`, and a physical-device pane has no
    /// owned-booted-sim fallback, so without this the daemon could exit while a
    /// backend, a tunnel, or a final lift was still outstanding.
    private var deferredCleanups: Int = 0
    /// Source of `Record.attachment`. Monotonic across the coordinator, so a
    /// value is unique to one admission of one record and a stale close can
    /// never coincide with a live admission.
    private var nextAttachment: UInt64 = 1
    /// Cohort membership, owned here rather than in its own actor because it
    /// and the pane records form one consistency domain: a membership change
    /// decides who may drive a pane and rebinds records, and those have to be
    /// visible together. See `SessionCohortState`.
    private var cohortState = SessionCohortState()
    /// Where cohort transitions send their device consequences: the effect
    /// pump's synchronous enqueue, installed by `installCohortWiring`.
    /// Yielded inside the commit turn, so emission order is this actor's
    /// commit order and the pump's single consumer applies effects to
    /// `DeviceCoordinator` in exactly that order. Out-of-order application
    /// is structurally impossible, with no sequence numbers to compare and
    /// no dedup to get wrong. `main.swift` asserts installation before the
    /// RPC servers bind; a nil sink outside tests would silently drop a
    /// transfer or a tombstone.
    private var deviceEffectSink: (@Sendable (CohortDeviceEffect) -> Void)?
    /// Whether the effect sink is installed. `main.swift` asserts this before
    /// binding the RPC servers, the same fail-closed rule as the revokers.
    public var hasDeviceEffectSink: Bool { deviceEffectSink != nil }
    /// PRODUCER-LOCAL active incarnation per session, pushed by `SessionManager`
    /// as a session reaches `.ready` (`noteSessionActive`) and CLEARED when its
    /// close sweep runs (`revokeSubscriptions(forSession:)`). Every pane
    /// ownership commit (fresh create, same-session re-attach, adoption flip)
    /// re-checks it SYNCHRONOUSLY, with no `await` before the mutation: a create
    /// authorized under incarnation G that resumes after the session was closed
    /// and restored at G+1 sees `activeIncarnation[session] == G+1 != G` and is
    /// refused, so it can't create/re-attach/adopt under a stale incarnation,
    /// clear `ownerRevoked`, or hand ownership to a closed session. A session not
    /// tracked here (a direct-on-actor test with no `SessionManager`) is
    /// un-checked; production always tracks a ready session before any create for
    /// it can arrive.
    private var activeIncarnation: [UUID: UInt64] = [:]
    /// Injected short_id mint strategy. Production uses
    /// `ShortID.generate()`; tests inject a deterministic sequence
    /// (e.g. forced collision-then-resolve) to exercise the retry
    /// path without depending on RNG luck.
    private let mintShortID: @Sendable () -> String
    /// Optional event broker. When non-nil, state transitions are published
    /// to it for the sessions currently permitted to drive the pane, so
    /// their `deviceterm events` subscribers (and the GUI peer) see pane
    /// lifecycle. Frame-driven
    /// transitions are awaited by the per-pane pump after their synchronous
    /// coordinator commit. Nil in tests that don't care about the broker,
    /// which keeps the existing test surface terse.
    private let eventBroker: EventBroker?
    /// Optional subscription registry. When non-nil, each surface
    /// callback delivers the `RetainedSurface` to the registry,
    /// which then routes it to the XPC-side delivery handle each
    /// subscriber registered. UDS subscribers don't register a
    /// handle, so they receive only the JSON evt via the
    /// per-record fan-out (no side-band surface payload: UDS
    /// can't carry an `xpc_object_t`).
    private let subscriptionRegistry: PaneSubscriptionRegistry?
    /// Test-only seam captured when a pane creates its pump. Always nil in
    /// production.
    private var surfacePumpTestHook: (@Sendable (SurfacePumpTestPoint) async -> Void)?

    /// Diagnostic accessor: live, listable pane records. Excludes retiring ones.
    public var paneCount: Int { panes.count }

    /// Whether any pane retirement is still in progress.
    ///
    /// The idle monitor samples this alongside `liveOwnerSessionIds`: a
    /// retiring pane's owner has already left that set, so without this the
    /// daemon could exit while a backend or tunnel was still held.
    public var hasDeferredCleanup: Bool {
        deferredCleanups > 0
    }

    /// SessionIds owning at least one non-terminal pane (booting or
    /// rendering). Terminal (shut-down/failed) records are excluded. The
    /// daemon's stay-alive predicate intersects this with session liveness:
    /// a pane whose owner GUI is still alive keeps the daemon up (even a
    /// physical-device pane, which has no CoreSimulator boot state to
    /// observe, and even across a momentary GUI-connection lapse) while a
    /// pane abandoned by a crashed GUI does not, so the daemon can still
    /// idle-exit and reap its tunnel keepalives.
    public var liveOwnerSessionIds: Set<UUID> {
        Set(
            panes.values
                .filter { $0.state != .shutdown && $0.state != .failed }
                .map(\.sessionId)
        )
    }

    public init(
        mintShortID: @Sendable @escaping () -> String = { ShortID.generate() },
        eventBroker: EventBroker? = nil,
        subscriptionRegistry: PaneSubscriptionRegistry? = nil
    ) {
        self.mintShortID = mintShortID
        self.eventBroker = eventBroker
        self.subscriptionRegistry = subscriptionRegistry
    }

    /// Test-only: install the ordered-pump race hook above.
    func setSurfacePumpTestHook(
        _ hook: @escaping @Sendable (SurfacePumpTestPoint) async -> Void
    ) {
        surfacePumpTestHook = hook
    }

    // MARK: - Create

    /// Spawn a sim pane against an already-booted simulator. The
    /// caller is responsible for validating session credentials
    /// upstream. `PaneCoordinator` doesn't see capabilities at all.
    ///
    /// Returns the current `IOSurfaceID` if one's already bound to
    /// the renderable (the bridge documents that `start(callback:)`
    /// fires synchronously when a surface is already available). If
    /// not, the pane state is `.booting` and the GUI should wait
    /// for the first `surface.changed` event before treating it as
    /// rendering.
    public func createSim(
        sessionId: UUID,
        udid: String,
        revision: UInt64? = nil,
        ownerIncarnation: UInt64? = nil,
        requireConcreteIncarnation: Bool = false,
        isOwnerSessionAlive: (@Sendable (UUID) async -> Bool)? = nil
    ) async throws -> PaneCreateResult {
        let normalized = try canonicalizeUDID(udid)
        return try await createPane(
            target: .sim(udid: normalized),
            sessionId: sessionId,
            revision: revision,
            ownerIncarnation: ownerIncarnation,
            requireConcreteIncarnation: requireConcreteIncarnation,
            isOwnerSessionAlive: isOwnerSessionAlive,
            acquire: { try self.acquireSimBackend(udid: normalized) }
        )
    }

    /// Backend-agnostic pane create. Runs the dedup/adopt-orphan loop
    /// keyed on the **full `PaneTarget`** (kind-qualified: a `.sim` and a
    /// `.device` with the same id text are distinct panes, never deduped or
    /// adopted against each other), then, only on a genuine fresh create,
    /// calls `acquire` to build the backend and starts its frame
    /// stream. Sim and physical create paths differ only in the `acquire`
    /// closure; everything here is identical for both.
    ///
    /// Dedup by the full kind-qualified `PaneTarget` (see `isLiveTarget`).
    /// Without it, racing callers (the GUI's
    /// discovery poll that fires after a shim boot AND an explicit
    /// attach from the same session, or duplicate shim events) each
    /// cut a fresh pane record for the same device. Result is two pane
    /// states side-by-side mirroring one underlying display, and
    /// downstream verbs that resolve by target hit "multiple panes"
    /// errors.
    ///
    /// Three branches inside the dedup:
    ///
    /// 1. Same session → return the existing pane's handle
    ///    (idempotent re-attach).
    /// 2. Different session AND the prior owner is still alive →
    ///    reject as a genuine conflict. The locked linkage design
    ///    reserves cross-session pane movement to the human (GUI
    ///    drag); a daemon-side steal would silently break the
    ///    original tab's stream.
    /// 3. Different session AND the prior owner is dead → adopt the
    ///    pane into the new session by rewriting `Record.sessionId`.
    ///    This is the orphan-recovery path: the GUI crashed leaving
    ///    the daemon holding the pane; on relaunch, the recovery sheet
    ///    re-attaches with a fresh session. The backend stays attached
    ///    to the same device and continues streaming: no re-acquire.
    ///
    /// The `isOwnerSessionAlive` predicate distinguishes (2) from (3);
    /// callers pass a `SessionManager`-backed closure. With no
    /// predicate provided (test / pre-wired call sites), the safe
    /// default is "assume alive": reject cross-session, never
    /// silently adopt.
    ///
    /// **Actor reentrancy.** The predicate is `async`, so the actor
    /// yields across `await isOwnerSessionAlive(...)` and any other
    /// actor entry point can run in the gap. Three mutations can land
    /// in that window and invalidate our decision to adopt:
    ///
    ///   - Another create adopts the same record. The liveness answer
    ///     we cached is then about a session that no longer owns the
    ///     pane; adopting would silently steal it from the new owner.
    ///   - `close(paneId:as:mode:)` removes the record from `panes`
    ///     entirely. Mutating `existing.sessionId` afterwards touches
    ///     a record nobody's tracking and the returned handle points
    ///     at a non-existent pane.
    ///   - `markPanesShutdown(forUDID:)` transitions the record to
    ///     `.shutdown`. Adopting a shutdown pane hands the caller a
    ///     stale handle whose backend is gone.
    ///
    /// Guard against all three by snapshotting the owner before the
    /// await and re-validating after: the record must still be the
    /// same instance in `panes`, still non-terminal, and still owned
    /// by the snapshotted prior owner. Any mismatch restarts the
    /// `while` so we re-evaluate against the new state.
    ///
    /// `.shutdown` / `.failed` panes are skipped so an already-shut-
    /// down record doesn't block a reboot; a fresh `booted` event
    /// after a shutdown/boot cycle creates a fresh pane.
    func createPane(
        target: PaneTarget,
        sessionId: UUID,
        revision: UInt64? = nil,
        ownerIncarnation: UInt64? = nil,
        requireConcreteIncarnation: Bool = false,
        isOwnerSessionAlive: (@Sendable (UUID) async -> Bool)? = nil,
        acquire: () throws -> AcquiredBackend
    ) async throws -> PaneCreateResult {
        // Production pane ownership requires a CONCRETE target incarnation: the
        // handler resolves it from the target session's live phase (nil when the
        // session isn't ready), so a nil here means the target was torn down /
        // not ready and the create is refused. A concrete incarnation is what
        // the pane is stamped with; a stale one (session reincarnated after) is
        // harmless: the reincarnated session's requests carry the NEW
        // incarnation and the pane's incarnation gate rejects them, and a closed
        // session's requests are rejected at the dispatch admission gate. A
        // `nil` is allowed only for test/internal callers (`requireConcrete`
        // false), which are un-pinned.
        if requireConcreteIncarnation, ownerIncarnation == nil {
            throw PaneError.ownerNotReady(sessionId: sessionId)
        }
        // Synchronous producer-local active-incarnation check, called at each
        // ownership commit with no `await` before the mutation. For a PRODUCTION
        // call (`requireConcreteIncarnation`, i.e. a tracked owner) it requires
        // EXACT equality: a MISSING entry (the session's close sweep cleared it)
        // REJECTS, so a request that resumed after `session.close` returned can't
        // create/re-attach/adopt under a stale incarnation. Only an explicitly
        // untracked internal/test call (`requireConcreteIncarnation == false`)
        // bypasses.
        func ownerIncarnationStillActive() -> Bool {
            guard requireConcreteIncarnation else { return true }
            return activeIncarnation[sessionId] == ownerIncarnation
        }
        let key = target.key
        func resultFor(_ record: Record) -> PaneCreateResult {
            let (pixW, pixH) = record.displayPixelDimensions()
            return PaneCreateResult(
                paneId: record.id,
                attachment: record.attachment,
                scale: 1.0,
                family: record.family,
                shortId: record.shortId,
                name: record.name,
                deviceType: record.deviceType,
                pixelWidth: pixW,
                pixelHeight: pixH,
                capabilities: record.capabilities,
                target: record.target
            )
        }
        // Resolve the target's current owner, re-checking after every
        // suspension. A pane whose close deferred still owns its device while
        // the gesture runs, and a live pane can become one of those inside any
        // of the awaits below; attaching then would put two producers on one
        // digitizer, which is the interleaving the lane exists to prevent.
        while true {
            if retiring.values.contains(where: { $0.target == target }) {
                await awaitRetiringTarget(target)
                continue
            }
            guard let existing = panes.values.first(where: { isLiveTarget($0, target: target) }) else {
                break
            }
            if existing.transferring {
                // A transfer is quiescing this record: input is fenced and
                // ownership is mid-flip. Don't hand back a (half-transferred)
                // handle or race a competing adopt. Park on the explicit
                // completion handshake, then re-evaluate the settled state.
                await awaitTransferSettled(record: existing)
                continue
            }
            if existing.sessionId == sessionId {
                // The owning session re-attaching to its own pane: re-admit it
                // (clear any owner-revoked fence left by a prior close of this
                // UUID) and re-stamp the accepted incarnation with the caller's
                // concrete incarnation, so a restored same-UUID owner reaches its
                // pane while a request from the OLD incarnation still mismatches
                // the gate. Refuse (synchronously, no `await` before the mutation)
                // if the session's active incarnation no longer matches: a
                // close/reincarnation raced this re-attach, so a stale re-attach
                // can't clear the fence or re-stamp a dead incarnation.
                guard ownerIncarnationStillActive() else {
                    throw PaneError.ownerNotReady(sessionId: sessionId)
                }
                existing.ownerRevoked = false
                existing.acceptedIncarnation = ownerIncarnation
                // Only a revisioned re-attach re-admits the record. Advancing
                // for an unrevisioned one would retire a token its holder is
                // still using: that caller doesn't fence its own closes, so it
                // gains nothing, while whoever holds the current `attachment`
                // is a DIFFERENT caller that never sees this response, and its
                // next close would be refused with the pane left running. The
                // shim's contextual auto-attach reaches this on every command
                // run in a tab that already shows the sim, so it is the
                // ordinary case, not the exotic one. An unrevisioned re-attach
                // is therefore idempotent: same record, same admission.
                if let revision {
                    // Refuse one the requester already superseded. The daemon
                    // may handle two of one caller's requests in either order,
                    // and admitting the older would move the record to an
                    // `attachment` that caller never learns, silently
                    // invalidating the close it eventually sends.
                    guard admits(revision, over: existing) else {
                        throw PaneError.staleAttach(paneId: existing.id)
                    }
                    existing.attachment = allocateAttachment()
                    existing.admissionRevision = revision
                }
                return resultFor(existing)
            }
            let priorOwner = existing.sessionId
            let priorAlive = await isOwnerSessionAlive?(priorOwner) ?? true
            // Post-await re-validation: the record must still be the
            // same instance in `panes`, still non-terminal, still owned by
            // the snapshotted prior owner, and not mid-transfer (a transfer
            // may have started during the await). See the actor-reentrancy
            // note above for the mutations this guards against (concurrent
            // adopt, close, shutdown).
            guard
                let stillPresent = panes[existing.id],
                stillPresent === existing,
                existing.state != .shutdown,
                existing.state != .failed,
                existing.sessionId == priorOwner,
                !existing.transferring
            else {
                continue
            }
            if priorAlive {
                throw PaneError.paneAlreadyAttached(
                    udid: key,
                    ownerSessionId: priorOwner
                )
            }
            // Adopt via the quiesced transfer barrier: revoke the prior
            // owner's subscriptions, fence its in-flight input, then flip
            // ownership. A bail (a close/shutdown raced the transfer)
            // re-evaluates the loop rather than returning a stale handle; a
            // throw (input couldn't be quiesced) propagates as a clean
            // adoption failure the caller can retry.
            if try await transferOwnership(
                record: existing,
                to: sessionId,
                newOwnerIncarnation: ownerIncarnation,
                requireConcreteNewOwner: requireConcreteIncarnation
            ) {
                // The transfer committed, so this is a new admission: stamp it
                // before answering, or the adopting caller would be handed the
                // prior owner's value and a close from that owner would still
                // match. Unconditional, unlike the same-owner branch above:
                // the record genuinely changed hands, so the prior owner's
                // token must stop working whether or not the adopter tracks
                // revisions. The adopter's revision replaces the prior
                // owner's, which is why staleness is only ever compared within
                // one requester's own series.
                existing.attachment = allocateAttachment()
                existing.admissionRevision = revision
                return resultFor(existing)
            }
            continue
        }
        // Synchronous active-incarnation check immediately before the fresh
        // create commit (acquire + insert below run with no `await`): a create
        // that resumed after its session's close sweep sees a cleared/newer
        // active incarnation and is refused, so it can't mint a pane under a
        // stale incarnation.
        guard ownerIncarnationStillActive() else {
            throw PaneError.ownerNotReady(sessionId: sessionId)
        }
        let acquired = try acquire()
        let paneId = UUID()
        let shortId = try allocateUniqueShortID()
        let record = Record(
            id: paneId,
            sessionId: sessionId,
            attachment: allocateAttachment(),
            admissionRevision: revision,
            target: target,
            state: .booting,
            family: acquired.family,
            shortId: shortId,
            name: nil,
            deviceType: acquired.deviceType,
            capabilities: acquired.backend.capabilities.wire
        )
        record.backend = acquired.backend
        // Pin the pane to the creating owner's incarnation (nil for a
        // validated-GUI create, which is un-pinned).
        record.acceptedIncarnation = ownerIncarnation
        // Bind to the owner's cohort in the same turn the record is
        // admitted, so no window exists where a sibling's request against a
        // freshly created pane falls back to the own-session path. An owner
        // in no cohort, or an un-pinned create, stays unbound.
        record.cohortId = ownerIncarnation.flatMap {
            cohortState.cohortId(forMember: CohortMember(sessionId: sessionId, incarnation: $0))
        }
        panes[paneId] = record

        // Stand up the per-pane ordered surface pump before starting
        // frames: the backend can fire its callback synchronously
        // inside `startFrames` when a surface is already bound, so the
        // continuation must exist first. The callback only yields. The
        // detached serial drain asks this actor to commit each retained frame
        // in receive order, then performs steady-state side-band fan-out
        // without re-entering PaneCoordinator. The first frame re-enters once
        // to fence its lifecycle publication against teardown and session
        // revocation.
        let (surfaceStream, surfaceContinuation) = AsyncStream.makeStream(
            of: PublishedSurface.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        record.surfaceContinuation = surfaceContinuation
        let subscriptionRegistry = subscriptionRegistry
        let surfacePumpTestHook = surfacePumpTestHook
        record.surfacePump = Task.detached { [weak self, paneId] in
            for await published in surfaceStream {
                guard !Task.isCancelled else { break }
                await surfacePumpTestHook?(.beforeCommit)
                guard let work = await self?.handleSurfaceCallback(
                    paneId: paneId,
                    published: published
                ) else { continue }
                if let statePublication = work.statePublication {
                    await surfacePumpTestHook?(.beforeStatePublication)
                    await self?.publishSurfaceStateIfCurrent(statePublication)
                }
                guard !Task.isCancelled else { break }
                await subscriptionRegistry?.deliverSurface(
                    paneId: work.paneId,
                    published: work.published,
                    sequence: work.sequence
                )
            }
        }

        do {
            try acquired.backend.startFrames(
                onFrame: { published in
                    surfaceContinuation.yield(published)
                },
                onFatal: { [weak self, paneId] reason in
                    Task { [weak self, paneId] in
                        await self?.markPaneFailed(paneId: paneId, reason: reason)
                    }
                }
            )
        } catch {
            let surfacePump = record.teardownSurfacePump()
            panes.removeValue(forKey: paneId)
            await surfacePump?.value
            throw PaneError.startStreamFailed(
                udid: key,
                message: BridgeMessage.unwrap(error)
            )
        }

        startDisplayOrientationObserver(record: record, paneId: paneId, backend: acquired.backend)

        // The backend may fire the callback synchronously inside
        // `startFrames` when a surface is already bound. By the time we
        // get here, `record.currentSurface` may already reflect that.
        // If not, fall through to the first asynchronous callback.
        if record.currentSurface != nil {
            record.state = .rendering
        }
        // Publish the pane's initial state (booting or already-
        // rendering on attach-to-booted-device) to the event stream,
        // scoped to the sessions permitted to drive the pane. Subsequent
        // transitions get their own publishes in handleSurfaceCallback /
        // shutdown.
        await eventBroker?.publish(
            .paneStateChanged(
            paneId: paneId.uuidString,
            udid: record.target.key,
            state: record.state.rawValue
        ),
            to: .sessions(controllers(of: record))
        )
        return resultFor(record)
    }

    /// Predicate for the dedup loop: a record mirrors `target` and is
    /// not already torn down. Matches on the **full** `PaneTarget`, not
    /// its `.key` string: a `.sim(udid: "X")` and a `.device(deviceId:
    /// "X")` that happen to share text are distinct panes and must never
    /// dedup, adopt, or shut down against each other. Extracted from the
    /// `while` so the closure type-checks fast (a multi-clause boolean
    /// inside `first(where:)` strains the inference engine).
    private func isLiveTarget(_ record: Record, target: PaneTarget) -> Bool {
        record.target == target
            && record.state != .shutdown
            && record.state != .failed
    }

    /// Acquire the CoreSimulator bridge handles for a sim pane and wrap
    /// them in a `SimDeviceBackend`. Classifies the device family +
    /// human-readable type up front (best-effort: a lookup failure
    /// leaves the pane usable, just family-"unknown") so every attach
    /// path gets them from the daemon's response. Surfaces an
    /// unusable sim (display/HID/Purple acquisition failure) before the
    /// pane is recorded.
    private func acquireSimBackend(udid normalized: String) throws -> AcquiredBackend {
        let handle = try? SimDeviceHandle.handle(forUDID: normalized)
        let family = (
            handle
            .map { DeviceFamilyClassifier.classify($0.deviceTypeIdentifier) }
            ?? .unknown
            ).rawValue
        let deviceType: String? = handle.flatMap {
            $0.deviceTypeName.isEmpty ? nil : $0.deviceTypeName
        }
        let displayHandle: SimDisplayHandle
        do {
            displayHandle = try SimDisplayHandle.handle(forUDID: normalized)
        } catch {
            throw PaneError.deviceNotFound(udid: normalized)
        }
        // Acquire HID + Purple clients up front. Both go through the
        // same bridge load + sim lookup as the display handle, so
        // failures here mean the sim isn't actually usable, so surface
        // them before we record the pane.
        let hidClient: SimHIDClient
        do {
            hidClient = try SimHIDClient.client(forUDID: normalized)
        } catch {
            throw PaneError.hidUnavailable(
                udid: normalized,
                message: BridgeMessage.unwrap(error)
            )
        }
        let purpleClient: SimPurpleHID
        do {
            purpleClient = try SimPurpleHID.client(forUDID: normalized)
        } catch {
            throw PaneError.hidUnavailable(
                udid: normalized,
                message: BridgeMessage.unwrap(error)
            )
        }
        let backend = SimDeviceBackend(
            udid: normalized,
            displayHandle: displayHandle,
            hidClient: hidClient,
            purpleClient: purpleClient
        )
        return AcquiredBackend(backend: backend, family: family, deviceType: deviceType)
    }

    // MARK: - Subscribe

    /// Begin streaming pane events. The returned subscription id
    /// lets callers explicitly unsubscribe; in practice the RPC
    /// layer detects client disconnect and uses the `onCancel` hook.
    ///
    /// The producer-side continuation is finished when:
    ///   - The consumer explicitly unsubscribes.
    ///   - `close(paneId:as:mode:)` runs.
    func subscribe(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        context: SubscriptionContext? = nil
    ) async throws -> (subscriptionId: UUID, stream: AsyncStream<PaneEvent>) {
        // Ownership gate (`gatesInput: false`, because this is presentation, not
        // input, so a validated GUI keeps rendering across a transfer; a
        // `.session` principal is still denied while `transferring`).
        // Foreign and unknown both throw `notFound`, indistinguishable.
        let record = try authorize(paneId: paneId, as: principal, gatesInput: false)

        // Track this in-flight setup on the record so an ownership
        // transfer waits for a revocable (`.session`) setup to settle (its
        // surface token materialized) before collecting tokens to revoke. This
        // closes the mid-setup race where a subscribe suspended in
        // `registerSurfaceDelivery` would otherwise leave an orphan hook
        // the transfer never saw. `finishPendingSetup` resumes a waiting
        // transfer the instant the last revocable setup clears.
        let setupNonce = UUID()
        record.pendingSubscribeSetup[setupNonce] = principal
        defer { finishPendingSetup(record: record, nonce: setupNonce) }

        let subscriptionId = UUID()
        let (stream, continuation) = AsyncStream<PaneEvent>.makeStream()
        record.subscribers[subscriptionId] = Subscriber(
            continuation: continuation,
            principal: principal,
            subscriptionToken: context?.subscriptionToken,
            connectionId: context?.connectionId,
            lifecycle: context?.lifecycle
        )
        let recordId = paneId
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.unsubscribe(paneId: recordId, subscriptionId: subscriptionId)
            }
        }
        // The initial-state replay is deferred to *after* the terminal /
        // transfer re-checks below: a subscription that lost its
        // authorization mid-setup must throw, not hand back a stream that
        // already carries a buffered event.

        // Authorization precedes registration. The transport supplies a
        // pane-agnostic delivery capability on `context`; register that token
        // only against the authorized pane so a rejected foreign subscription
        // creates no side-band slot. UDS (nil context) supplies no surface lane.
        if let context {
            await subscriptionRegistry?.registerSurfaceDelivery(
                paneId: paneId,
                connectionId: context.connectionId,
                subscriptionId: context.subscriptionToken,
                surfaceDelivery: context.surfaceDelivery
            )
            // Registration follows the handler's authorization suspension, so
            // connection teardown may already have run. Attach unregistering
            // to the lifecycle: `installSurfaceTeardown` runs it immediately if
            // a terminal cause already fired, and `fire` runs it if one fires
            // later.
            let registry = subscriptionRegistry
            let token = context.subscriptionToken
            await context.lifecycle.installSurfaceTeardown { [weak registry] in
                await registry?.unregister(subscriptionId: token)
            }
        }

        // Device panes register the subscription's lease token with the
        // pool and install the lifecycle's pool teardown BEFORE the
        // surface replay, so a token-bearing side-band observes a
        // registered token and any teardown cause that raced the
        // subscribe applies to a wired token. Sim panes carry the token
        // for correlation but take no pool registration; UDS (nil
        // context) skips both.
        if let context, case .device = record.target, let backend = record.backend {
            await backend.registerLeaseToken(
                context.subscriptionToken,
                connectionId: context.connectionId
            )
            let token = context.subscriptionToken
            await context.lifecycle.installPoolTeardown { [weak backend] cause in
                guard let backend else { return }
                switch cause {
                case .drain:
                    // Graceful: drop the token if it holds nothing,
                    // else drain and let outstanding leases release via
                    // acks.
                    if await backend.unregisterLeaseTokenIfUnused(token) == false {
                        await backend.drain(token: token)
                    }

                case .orphan:
                    await backend.orphan(token: token)
                }
            }
        }

        // A `.session` subscribe that authorized *before* an ownership
        // transfer set the marker and then suspended in its registration
        // awaits lost its authorization: the transfer has revoked the prior
        // owner's access, so this late setup must not survive it. Tear it
        // down fully and **throw**; returning a stream would ack success
        // (and could carry a buffered event) after ownership was lost. (A
        // `.guiPeer` subscribe legitimately spans the transfer and keeps
        // rendering the pane.)
        if record.transferring, case .session = principal {
            await revokeSubscriber(record: record, subscriptionId: subscriptionId)
            throw PaneError.notFound(paneId: paneId)
        }

        // Don't replay into a subscription a terminal cause has already torn
        // down: a `pane.surfaceDrain` that raced setup, or a connection
        // close. Returning the (to-be-finished) stream is the graceful drain
        // contract, *unless* the pane was closed out from under us (record
        // gone), in which case throw.
        if let context, await context.lifecycle.hasTerminalCause() {
            guard panes[paneId] === record else {
                await revokeSubscriber(record: record, subscriptionId: subscriptionId)
                throw PaneError.notFound(paneId: paneId)
            }
            return (subscriptionId, stream)
        }

        // Cleared every re-check: activate the (dormant) surface hook so it
        // begins delivering, then replay the current state. Activation
        // *after* the terminal/transfer checks means no frame can ship into
        // a subscription that was about to be torn down.
        if let context {
            await subscriptionRegistry?.activate(subscriptionId: context.subscriptionToken)
        }
        continuation.yield(.stateChanged(paneId: paneId, state: record.state))
        // Replay the pane's presentation orientation too, before any frame:
        // a subscriber that wasn't listening when it last changed (a
        // reconnect gap, a GUI that relaunched onto a pane the daemon kept)
        // would otherwise never learn of it, and would render and hit-test a
        // landscape pane as portrait until the next change. It matches the
        // framebuffer where the backend is observed, and reflects the last
        // performed command where it isn't. Before the first seed,
        // observation, or command it is the `.portrait` assumption.
        continuation.yield(
            .orientationChanged(paneId: paneId, orientation: record.presentationOrientation)
        )

        if record.lastSequence > 0, let published = record.currentSurface {
            continuation.yield(
                .surfaceChanged(
                paneId: paneId,
                sequence: record.lastSequence
            )
                )
            // Side-band: re-deliver the surface to the new subscription
            // only (token-targeted), so adding a subscriber doesn't
            // re-grant the current frame to every existing one. UDS (no
            // token, no XPC delivery handle) takes neither branch.
            if let token = context?.subscriptionToken {
                await subscriptionRegistry?.deliverSurface(
                    to: token,
                    published: published,
                    sequence: record.lastSequence
                )
            }
        }

        // FINAL re-authorization happens after the *last* suspension (the surface
        // replay above) and with no `await` before the successful return: a
        // transfer or close that raced any setup await (terminal inspection,
        // activation, or the replay itself) is caught here, so the caller
        // never receives a stream after ownership was lost. On failure fully
        // revoke and throw; the registry's own token unregister backs this up
        // for any frame that shipped during the replay race.
        do {
            _ = try authorize(paneId: paneId, as: principal, gatesInput: false)
        } catch {
            await revokeSubscriber(record: record, subscriptionId: subscriptionId)
            throw PaneError.notFound(paneId: paneId)
        }
        return (subscriptionId, stream)
    }

    /// Apply a cumulative surface-release watermark to a device pane's
    /// pool. The pool honors it only from the connection that registered
    /// the token (`connectionId`), so a foreign peer's ack (including any
    /// UDS peer, which registers no token) is a counted no-op.
    public func releaseWatermark(
        paneId: UUID,
        token: UUID,
        epoch: UInt64,
        lowestHeld: UInt64,
        connectionId: UInt64
    ) async {
        guard let record = panes[paneId], let backend = record.backend else { return }
        await backend.releaseWatermark(
            token: token,
            epoch: epoch,
            lowestHeld: lowestHeld,
            connectionId: connectionId
        )
    }

    public func unsubscribe(paneId: UUID, subscriptionId: UUID) {
        guard let record = panes[paneId] else { return }
        if let subscriber = record.subscribers.removeValue(forKey: subscriptionId) {
            subscriber.continuation.finish()
        }
    }

    /// Number of active subscribers on a pane. Used by tests.
    public func subscriberCount(paneId: UUID) -> Int {
        panes[paneId]?.subscribers.count ?? 0
    }

    // MARK: - Ownership transfer (adoption)

    /// Revoke one subscription completely. Synchronously removes it from
    /// the record and finishes its JSON continuation. That is the *entire*
    /// teardown for a UDS subscriber, which has no surface lane. For an
    /// XPC subscriber, the surface token's `unregister` runs **before** the
    /// lifecycle drain: `unregister` removes the registry entry, discards
    /// the delivery worker's queued frame, and drops the indexes in one
    /// actor turn: the concrete no-further-send fence (any in-flight leased
    /// transaction revalidates at its next `await`, finds the entry gone,
    /// and cancels/revokes instead of sending). `lifecycle.fire(.drain)` can
    /// then suspend inside device-pool teardown without a reentrant surface
    /// callback admitting another delivery, because the entry is already
    /// gone. The lifecycle's own surface teardown makes the double
    /// unregister idempotent. Idempotent overall.
    private func revokeSubscriber(record: Record, subscriptionId: UUID) async {
        guard let subscriber = record.subscribers.removeValue(forKey: subscriptionId) else { return }
        subscriber.continuation.finish()
        if let token = subscriber.subscriptionToken {
            await subscriptionRegistry?.unregister(subscriptionId: token)
        }
        if let lifecycle = subscriber.lifecycle {
            await lifecycle.fire(.drain)
        }
    }

    /// The shared revocation primitive: revoke every subscriber on `record`
    /// whose principal is `.session(target)`. BOTH ownership transfer
    /// (adoption) and session-close subscription revocation
    /// (`revokeSubscriptions(forSession:)`) call this, so a prior subscriber
    /// can never follow a pane across either boundary: one revocation path,
    /// not parallel code. The caller must have already fenced new setups
    /// (marked `record.transferring` and awaited `awaitRevocableSetupDrained`)
    /// so the token set is complete. A validated `.guiPeer` subscriber is
    /// spared (it spans sessions). Snapshot the ids first; `revokeSubscriber`
    /// mutates `subscribers`, so we can't iterate it live.
    ///
    /// Returns the number of revoked subscribers. Zero means no revocable
    /// subscriber was present; spared `.guiPeer` subscribers do not count.
    @discardableResult
    private func revokeSessionSubscribers(record: Record, target: UUID) async -> Int {
        let ids = record.subscribers.compactMap { id, subscriber in
            isRevocable(subscriber, priorOwner: target) ? id : nil
        }
        for subscriptionId in ids {
            await revokeSubscriber(record: record, subscriptionId: subscriptionId)
        }
        return ids.count
    }

    /// Record a session's active incarnation (pushed by `SessionManager` when it
    /// reaches `.ready`). Read synchronously by the ownership-commit check.
    public func noteSessionActive(_ sessionId: UUID, incarnation: UInt64) {
        activeIncarnation[sessionId] = incarnation
    }

    /// Revoke every subscription owned by a closing session, across every
    /// pane record: the session-close half of the revocation contract. Uses
    /// the SAME primitive adoption uses (`revokeSessionSubscribers` under the
    /// `transferring` quiescence), so an old subscriber can't outlive its
    /// session close. `.guiPeer` subscriptions are untouched; the GUI keeps
    /// rendering an orphan pending re-adoption. This is a lean subset of
    /// `transferOwnership`: NO ownership flip and NO input-generation dance.
    /// In-flight input from the closing session (a paced swipe) is allowed to
    /// finish against the now-orphaned pane; if that orphan is later
    /// re-adopted, `transferOwnership`'s input fence cancels any still-running
    /// input at the moment a new owner appears, so that concern is covered by
    /// adoption and not duplicated here.
    public func revokeSubscriptions(forSession sessionId: UUID) async {
        // Clear the session's active incarnation SYNCHRONOUSLY, before any await,
        // so a concurrent create/re-attach/adoption for it that captured the old
        // incarnation fails its synchronous commit check (the session is being
        // torn down; nothing may newly own a pane under it until it is restored
        // and re-activated at a new incarnation).
        let incarnation = activeIncarnation[sessionId]
        activeIncarnation[sessionId] = nil
        // Snapshot the record ids: the sweep suspends, and a record may be
        // adopted/removed across our awaits, so re-fetch each by id.
        var revokedCount = 0
        for recordId in Array(panes.keys) {
            revokedCount += await revokeSessionSubscriptionsOnRecord(
                recordId: recordId,
                sessionId: sessionId
            )
        }
        // Log nonzero revocations: a spared `.guiPeer` subscriber keeps the
        // pane rendering while every `.session`-principal call against that
        // paneId starts failing, so the two look different from the outside.
        // The session id stays out of the log; the incarnation is a small
        // counter that identifies nothing on its own.
        if revokedCount > 0 {
            DiagnosticLog.session.notice(
                """
                revoked \(revokedCount, privacy: .public) subscription(s) \
                incarnation=\(incarnation ?? 0, privacy: .public)
                """
            )
        }
    }

    /// Revoke a closing session's subscriptions on one record. Loops so a
    /// record found mid-transfer is re-evaluated after the transfer settles
    /// (which may leave it foreign-owned or, after an aborted transfer, still
    /// owned by the closing session).
    ///
    /// Returns how many subscribers it revoked on this record, so the caller
    /// can report real revocations rather than records examined.
    @discardableResult
    private func revokeSessionSubscriptionsOnRecord(recordId: UUID, sessionId: UUID) async -> Int {
        while let record = panes[recordId] {
            let ownedByClosing = record.sessionId == sessionId
            // A stray `.session(sessionId)` subscriber on a FOREIGN-owned
            // record (left over from before an adoption moved the pane away).
            let carriesStray = !ownedByClosing && record.subscribers.values.contains { subscriber in
                if case let .session(sid, _) = subscriber.principal { return sid == sessionId }
                return false
            }
            guard ownedByClosing || carriesStray else { return 0 }
            if record.transferring {
                // An adoption is quiescing this record; a second writer would
                // corrupt its single `transferSetupWaiter`. Wait for the
                // transfer to settle, then re-evaluate the settled owner.
                await awaitTransferSettled(record: record)
                continue
            }
            if ownedByClosing {
                // Owned by the closing session: run the same quiescence
                // adoption uses (mark `transferring` + bump `epoch` before the
                // first await, so a new `.session(sessionId)` subscribe is
                // denied and an in-flight one aborts at its post-setup check.
                // This closes the orphan-hook race where a subscribe dispatched
                // before the session close resumes and re-installs after the
                // sweep). Drain revocable setups, revoke any `.session(sessionId)`
                // subscribers (sparing `.guiPeer`), then mark the record
                // owner-revoked, fencing EVERY pane the closing session owns,
                // even a subscriber-less one, so a parked `.session(sessionId)`
                // subscribe stays refused after the marker clears, and clear the
                // marker so the now-orphaned pane can still be adopted later by a
                // validated-GUI recovery session.
                record.transferring = true
                record.epoch &+= 1
                await awaitRevocableSetupDrained(record: record)
                let revoked = await revokeSessionSubscribers(record: record, target: sessionId)
                record.ownerRevoked = true
                await awaitSurfaceStatePublication(record)
                await surfacePumpTestHook?(.beforeTerminalPublicationWait)
                await awaitTerminalStatePublication(record)
                clearTransferring(record)
                return revoked
            }
            // Foreign-owned but carries a stray `.session(sessionId)`
            // subscriber: revoke directly; `authorize` already forbids a NEW
            // `.session(sessionId)` setup on a foreign-owned record, so no
            // quiescence is needed.
            return await revokeSessionSubscribers(record: record, target: sessionId)
        }
        return 0
    }

    /// Await (via an explicit handshake, not a poll) until no revocable
    /// (`.session`) subscribe setup remains in flight on `record`, so the
    /// transfer collects a *complete* set of surface tokens to revoke. New
    /// `.session` setups can't begin during a transfer (`authorize` denies
    /// them) and a permitted `.guiPeer` setup never blocks, so this always
    /// drains. `finishPendingSetup` resumes the waiter.
    private func awaitRevocableSetupDrained(record: Record) async {
        guard record.hasPendingSessionSetup else { return }
        await withCheckedContinuation { continuation in
            record.transferSetupWaiter = continuation
        }
    }

    /// Finish one in-flight subscribe setup (from `subscribe`'s `defer`).
    /// Resumes a transfer waiting on the revocable set the instant the
    /// last `.session` setup clears.
    private func finishPendingSetup(record: Record, nonce: UUID) {
        record.pendingSubscribeSetup[nonce] = nil
        if let waiter = record.transferSetupWaiter, !record.hasPendingSessionSetup {
            record.transferSetupWaiter = nil
            waiter.resume()
        }
    }

    /// Clear the transfer marker and wake every `createPane` caller parked
    /// on this record's transfer. The single exit gate for `transferring`.
    private func clearTransferring(_ record: Record) {
        record.transferring = false
        let waiters = record.transferCompletionWaiters
        record.transferCompletionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        // A revocable-setup waiter that never fired (no `.session` setup
        // completed) must not leak past the transfer.
        if let setupWaiter = record.transferSetupWaiter {
            record.transferSetupWaiter = nil
            setupWaiter.resume()
        }
    }

    /// Park a `createPane` caller until `record`'s in-flight transfer
    /// clears, so it never observes the half-transferred state (a handle
    /// whose input is still fenced) or races a concurrent adopt.
    private func awaitTransferSettled(record: Record) async {
        guard record.transferring else { return }
        await withCheckedContinuation { record.transferCompletionWaiters.append($0) }
    }

    /// Whether a subscriber is revoked by an adoption: the prior owner's
    /// own `.session` subscriptions are torn down; a validated `.guiPeer`
    /// subscription spans the transfer and keeps rendering.
    private func isRevocable(_ subscriber: Subscriber, priorOwner: UUID) -> Bool {
        if case let .session(sid, _) = subscriber.principal { return sid == priorOwner }
        return false
    }

    /// Quiesced ownership transfer (adoption). `record` is the live orphan
    /// and `newOwner` the adopting session. Returns `true` once ownership
    /// has flipped to `newOwner` **and** a live, usable pane remains for
    /// the adopter; `false` if a close/shutdown/fail raced in (the caller
    /// re-evaluates). A **competing** adoption can't race this:
    /// `createPane`'s loop parks on `transferring` (set synchronously in
    /// step 1 before the first `await`), so the only concurrent mutators
    /// here are close / shutdown / fail, each of which bumps `epoch`.
    ///
    /// The ownership flip (step 6) is the explicit commit point. Before it,
    /// a bail restores the prior owner's input generation (never rewrites
    /// ownership: there is nothing to undo). After it, the pane is
    /// committed to `newOwner` and finalization runs under the new owner
    /// with no old-owner recovery.
    @discardableResult
    private func transferOwnership(
        record: Record,
        to newOwner: UUID,
        newOwnerIncarnation: UInt64? = nil,
        requireConcreteNewOwner: Bool = false
    ) async throws -> Bool {
        // (1) Stop admission before the first await. The marker denies
        // `.session` subscription and all-principal *input* for the whole
        // sequence (`authorize`), so no input enqueues into the generation
        // being torn down and the prior owner can't re-subscribe.
        record.transferring = true
        let priorOwner = record.sessionId
        record.epoch &+= 1
        let startEpoch = record.epoch

        // Pre-flip, the record must still be the same live orphan under its
        // prior owner. Close removes it; shutdown/fail bump `epoch` and go
        // terminal.
        func stillTransferable() -> Bool {
            panes[record.id] === record
                && record.epoch == startEpoch
                && record.sessionId == priorOwner
                && record.state != .shutdown
                && record.state != .failed
        }

        // (2) Wait for every revocable prior-owner subscribe setup to
        // settle so its surface token is collectable before we revoke.
        await awaitRevocableSetupDrained(record: record)
        guard stillTransferable() else { abortBeforeFlip(record: record, expectedOwner: priorOwner); return false }

        // (3) Revoke the prior owner's subscriptions only; a validated
        // `.guiPeer` subscription spans the transfer and keeps rendering.
        // The SAME revocation primitive a session close uses
        // (`revokeSessionSubscribers`), so an old subscriber can't follow a
        // pane into its new session by either boundary.
        await revokeSessionSubscribers(record: record, target: priorOwner)

        // (4) Quiesce old-generation input through the backend's transfer
        // fence: discard buffered/queued input with cancellation, release
        // held contacts, and await the no-further-send fence. This is the
        // *terminal* input cleanup: release/lift lands only once stale
        // work can no longer send. If a held-input release *fails*, the
        // device can't be guaranteed input-clean, so abort rather than flip
        // ownership onto it (a failed relay send isn't proof the tunnel is
        // down: it can be transient).
        // Fence the lane first, then quiesce the backend below: that quiesce
        // invalidates the holder's remaining sends and frees the contact, so
        // the lane emits nothing and only has to stop handing the pane out.
        await record.contactLane?.transfer()
        let inputClean = await record.backend?.quiesceInputForTransfer() ?? true

        // (5) Re-validate after the awaits. Bail if a close/shutdown/fail
        // raced in. Check this **before** the quiesce verdict: if the record
        // was retired mid-quiesce (its backend torn down), a `false` from
        // quiesce is an artifact of that teardown, not a genuine failure.
        // Re-evaluate (→ fresh create) rather than throwing `inputNotQuiesced`.
        guard stillTransferable() else { abortBeforeFlip(record: record, expectedOwner: priorOwner); return false }
        guard inputClean else {
            abortBeforeFlip(record: record, expectedOwner: priorOwner)
            throw PaneError.inputNotQuiesced(paneId: record.id)
        }
        // Synchronous new-owner active-incarnation check, immediately before the
        // flip with no `await` after it. For a PRODUCTION adoption
        // (`requireConcreteNewOwner`) require EXACT equality: a MISSING entry
        // (the new owner's close sweep cleared it) REJECTS, so an adoption that
        // resumed after the adopting session closed can't attach device
        // ownership to it. An untracked internal/test adoption bypasses.
        if requireConcreteNewOwner, activeIncarnation[newOwner] != newOwnerIncarnation {
            abortBeforeFlip(record: record, expectedOwner: priorOwner)
            throw PaneError.ownerNotReady(sessionId: newOwner)
        }
        // (6) COMMIT POINT: flip ownership. The pane is stamped with
        // `newOwnerIncarnation` (the caller's concrete incarnation); if the new
        // owner was closed/reincarnated during the transfer's awaits, that
        // stamp is stale, and the incarnation gate + dispatch admission reject a
        // now-mismatched or closed-session request against the pane. Re-owning the pane by a live
        // session clears the persistent owner-revoked fence (if this orphan
        // was previously swept by a session close), so the new owner's
        // `.session` principal reaches it.
        record.sessionId = newOwner
        record.ownerRevoked = false
        record.acceptedIncarnation = newOwnerIncarnation
        // The cohort rides with the ownership: rebind to the adopter's
        // cohort, or to none. Leaving the prior owner's binding standing
        // would keep that cohort's sessions authorized on a pane that now
        // belongs to another.
        record.cohortId = newOwnerIncarnation.flatMap {
            cohortState.cohortId(forMember: CohortMember(sessionId: newOwner, incarnation: $0))
        }
        // The outgoing cohort's siblings were admitted to this record's
        // streams while it was theirs, and step (3) revoked only the prior
        // owner. Authorization refuses their next request; this tears down
        // what they already hold, the same non-member invariant sweep a
        // reconcile runs, or their surface callbacks would keep flowing
        // across the cohort change. `.guiPeer` is spared, and the sweep runs
        // under the still-set `transferring` fence so no new `.session`
        // setup can slip in behind it.
        let admitted: Set<UUID>
        if let cohortId = record.cohortId {
            admitted = Set(cohortState.members(ofCohort: cohortId).map(\.sessionId))
        } else {
            admitted = [newOwner]
        }
        let stale = Set(
            record.subscribers.values.compactMap { subscriber -> UUID? in
                guard case let .session(sessionId, _) = subscriber.principal,
                    !admitted.contains(sessionId) else { return nil }
                return sessionId
            }
        )
        for sessionId in stale {
            await revokeSessionSubscribers(record: record, target: sessionId)
        }
        // The prior owner's location claim does not follow the pane to its
        // new owner: it describes a write the new owner never made. Drop it
        // here rather than sending a `clear`, since the device's actual
        // simulated position is unchanged by a change of owner. Only
        // deviceterm's knowledge of who asked for it is.
        record.simulatedLocation = nil
        record.locationEpoch &+= 1
        record.epoch &+= 1
        let postFlipEpoch = record.epoch

        // (7) Finalize under the NEW owner. A shutdown/fail/close that
        // raced the flip preserves identity+owner but bumps `epoch`, clears
        // the backend, and goes terminal, so revalidate epoch, state, and
        // backend presence, not just identity+owner.
        let survived = panes[record.id] === record
            && record.epoch == postFlipEpoch
            && record.sessionId == newOwner
            && record.state != .shutdown
            && record.state != .failed
            && record.backend != nil
        if survived { record.backend?.resumeInput() }
        clearTransferring(record)
        // The flip is committed to `newOwner` either way; report success
        // only when a live, usable pane remains. A terminal race returns
        // false so `createPane` re-evaluates (and does a fresh create).
        return survived
    }

    /// Pre-flip abort: the ownership flip (step 6) has NOT happened, so the
    /// record is still the prior owner's. Restore its input generation
    /// (step 4 invalidated it) unless a shutdown/close already retired it,
    /// and clear the marker. Never rewrites ownership; there was no flip
    /// to undo. Only ever reached before the commit point, so the record's
    /// owner is still `expectedOwner` whenever the record survives.
    private func abortBeforeFlip(record: Record, expectedOwner: UUID) {
        if panes[record.id] === record {
            assert(
                record.sessionId == expectedOwner,
                "pre-flip abort saw ownership already changed; a flip leaked before the commit point"
            )
            if record.state != .shutdown, record.state != .failed {
                record.backend?.resumeInput()
            }
        }
        clearTransferring(record)
    }

    // MARK: - Shutdown

    /// Transition every pane attached to `udid` to `.shutdown`
    /// and yield `state.changed` to each subscriber. Called by
    /// ShimMethods on a shim `shutdown` event so the GUI's
    /// pane.subscribe stream reflects "the sim is gone". Without
    /// this, IOSurface frames just stop arriving and the user sees
    /// a frozen last frame with no signal. Display/HID handles are
    /// dropped here too (they reference a sim that no longer
    /// exists); the pane record stays so the GUI can show the
    /// shutdown overlay and offer Reboot. Idempotent.
    public func markPanesShutdown(forUDID udid: String) async {
        let normalized = (try? canonicalizeUDID(udid)) ?? udid
        for record in panes.values {
            // Sim shutdown matches sim panes only. Matching on `.key`
            // would let a sim shutdown tear down a physical-device pane
            // whose `deviceId` shares the sim's UDID text.
            guard case let .sim(simUDID) = record.target,
                simUDID == normalized,
                record.state != .shutdown else { continue }
            await retire(record: record, to: .shutdown)
        }
    }

    /// Drive one pane record into a terminal state, the shared body of the
    /// two ways a pane dies: a sim shutdown notification and an
    /// unrecoverable backend fault. Ordering matters here, so the whole
    /// sequence lives in one place rather than being kept in step by hand
    /// across two call sites.
    ///
    /// Releasing `currentSurface` drops the record's surface hold, so the
    /// IOSurface can be reclaimed once no holder remains.
    ///
    /// Dropping `simulatedLocation` is bookkeeping, not a command. deviceterm
    /// sends no `clear` and neither backend offers a getter, so once the
    /// backend is torn down deviceterm can no longer know whether the
    /// simulated position still stands. A shut-down device probably lost it
    /// with the rest of its state, but that is a guess, and `nil` is the
    /// value that doesn't guess. This is also the reboot path, since a live
    /// reboot runs shutdown then boot through `device.shutdown`, so the pane
    /// comes back making no claim.
    ///
    /// Callers own the decision to retire: each keeps its own selection and
    /// already-terminal guard, which differ (a sim shutdown still retires a
    /// `.failed` pane; a fault leaves either terminal state alone).
    private func retire(record: Record, to state: PaneLifecycle) async {
        record.terminalPublicationRevision &+= 1
        let terminalPublicationRevision = record.terminalPublicationRevision
        record.terminalStatePublicationInFlight = true
        let surfacePump = record.teardownSurfacePump()
        record.teardownOrientationPump(backend: record.backend)
        shutDownBackend(for: record)
        record.currentSurface = nil
        record.simulatedLocation = nil
        record.locationEpoch &+= 1
        record.state = state
        record.epoch &+= 1

        // A detached pump may already have committed work or queued its actor
        // call when cancellation lands. Wait for that one task to finish before
        // emitting terminal events. The handler's state/epoch fence
        // rejects work that had not committed yet; admitted work finishes
        // before subscribers can observe the terminal state.
        await surfacePump?.value
        guard panes[record.id] === record,
            record.state == state else {
            finishTerminalStatePublication(record, revision: terminalPublicationRevision)
            return
        }

        for subscriber in record.subscribers.values {
            subscriber.continuation.yield(.stateChanged(paneId: record.id, state: state))
        }
        // Publish to the event stream, scoped to the sessions permitted to
        // drive the pane, so their `deviceterm events` subscribers see pane
        // lifecycle.
        await eventBroker?.publish(
            .paneStateChanged(
                paneId: record.id.uuidString,
                udid: record.target.key,
                state: state.rawValue
            ),
            to: .sessions(controllers(of: record))
        )
        finishTerminalStatePublication(record, revision: terminalPublicationRevision)
    }

    /// Fail a pane whose backend reported an unrecoverable fault (a
    /// surface pool exhausted past its one controlled recovery). Tears down
    /// the surface pump + backend, transitions to `.failed`, and notifies
    /// subscribers so the GUI shows an error overlay instead of a frozen
    /// mirror. Idempotent; a no-op for an already-terminal pane.
    public func markPaneFailed(paneId: UUID, reason: String) async {
        guard let record = panes[paneId],
            record.state != .failed, record.state != .shutdown else { return }
        await retire(record: record, to: .failed)
    }

    // MARK: - Close

    /// Tear down a pane.
    ///
    /// The pane leaves `panes` immediately and its target is reserved until the
    /// teardown and `externalCleanup` have both finished, so a re-create can't
    /// attach to a device this close is about to shut down. `externalCleanup`
    /// is where the RPC layer performs what only it owns (the tunnel release
    /// and `DeviceCoordinator.shutdown`), keeping pane lifecycle and device
    /// lifecycle decoupled while running inside that reservation.
    ///
    /// The returned `PaneCloseResult` carries an action-free ack. When cleanup
    /// can't finish inline, because a gesture is still holding contact or a
    /// held contact needs retrying, it also carries a `deferral` to await; when
    /// it did finish inline, `cleanupError` reports what `externalCleanup`
    /// said.
    /// `expecting` fences the close to one admission of the record. When it
    /// is supplied and no longer matches, the close is a no-op: the record the
    /// caller meant to retire has since been re-admitted (a same-owner
    /// re-attach, or an adoption after its owner died) and belongs to whoever
    /// holds the newer value. A caller with no value to check omits it and
    /// gets the unconditional close, which is what the CLI's `pane close`
    /// does.
    func close(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        mode: PaneCloseMode,
        expecting attachment: UInt64? = nil,
        externalCleanup: PaneExternalCleanup? = nil
    ) async -> PaneCloseResult {
        // Ownership gate. Unknown and foreign both resolve to "nothing to
        // close." Close stays non-throwing because a `device.shutdown` sweep
        // may remove the pane just before the GUI close; that benign race must
        // not surface a user-visible error. A foreign paneId is likewise
        // indistinguishable from an unknown one, with no
        // foreign-paneId log line (that would itself be an existence
        // oracle for a same-user attacker). `gatesInput: false` so a
        // validated GUI close still lands mid-transfer; it removes the
        // record and the transfer's post-`await` re-validation then bails.
        guard let record = try? authorize(paneId: paneId, as: principal, gatesInput: false) else {
            return PaneCloseResult(outcome: PaneCloseOutcome(udidToShutdown: nil), deferral: nil)
        }
        // Checked in the same synchronous segment as the removal below, so a
        // re-admission can't land between the two.
        if let attachment, record.attachment != attachment {
            return PaneCloseResult(outcome: PaneCloseOutcome(udidToShutdown: nil), deferral: nil)
        }
        panes.removeValue(forKey: paneId)
        record.epoch &+= 1
        // Reserve the target for the whole close, not just the deferred kind.
        // Everything below this point suspends, and the external shutdown runs
        // later still; a create resolving in that window would attach to a
        // device this close is about to tear down.
        retiring[record.id] = record
        deferredCleanups += 1
        // A physical-device pane holds a tunnel keepalive; signal the RPC
        // layer to release it. Sim panes leave this nil.
        let deviceTunnelToRelease: String?
        if case let .device(deviceId) = record.target {
            deviceTunnelToRelease = deviceId
        } else {
            deviceTunnelToRelease = nil
        }
        // Revoke every subscriber *fully* before tearing the backend down:
        // finish the JSON continuation, and for an XPC subscriber fire its
        // lifecycle teardown (pool drain) and unregister its surface hook.
        // finishing the continuation alone would leak the pool token and the
        // side-band delivery entry. Done while the backend is still live so
        // the pool drain lands.
        for subscriptionId in Array(record.subscribers.keys) {
            await revokeSubscriber(record: record, subscriptionId: subscriptionId)
        }
        let udidToShutdown = mode == .shutdown ? record.target.key : nil
        // Stop admitting, wake anything queued, and free a live contact whose
        // producer walked away. An active composite is left to finish.
        let lane = record.contactLane
        await lane?.close()
        // Ask the lane first. A gesture still holding the digitizer owns that
        // contact, and probing the backend here would send a lift into the
        // middle of it; the deferred task retries once the gesture is done.
        var needsDeferral = await lane?.hasActiveComposite == true
        if !needsDeferral, mode == .detach, let backend = record.backend {
            // No gesture in flight, so whatever is still down was left behind.
            // A detach leaves the device running, so it has to come up before
            // the target is handed on, and that retry must not block the ack.
            needsDeferral = await backend.releaseHeldContact() == false
        }
        if needsDeferral {
            // Cleanup can't finish inline: either a gesture still holds the
            // digitizer, or a contact left behind has to be retried. Tearing
            // the backend out now would strand that contact, so retire the pane
            // instead: gone to every caller, alive for the work that remains.
            deferTeardown(
                record: record,
                mode: mode,
                actions: PaneCloseOutcome(
                    udidToShutdown: udidToShutdown,
                    deviceTunnelToRelease: deviceTunnelToRelease
                ),
                externalCleanup: externalCleanup
            )
            return PaneCloseResult(
                outcome: PaneCloseOutcome(udidToShutdown: nil, deviceTunnelToRelease: nil),
                deferral: PaneCloseDeferral(paneId: record.id)
            )
        }
        await tearDownRetiring(record: record, mode: mode)
        // Inside the reservation: the target isn't free until the device has
        // actually been shut down and its tunnel released.
        let cleanupError = await externalCleanup?(
            PaneCloseOutcome(udidToShutdown: udidToShutdown, deviceTunnelToRelease: deviceTunnelToRelease)
        )
        finalizeRetirement(record: record)
        // The actions have already run, so the ack names none of them.
        return PaneCloseResult(
            outcome: PaneCloseOutcome(udidToShutdown: nil, deviceTunnelToRelease: nil),
            deferral: nil,
            cleanupError: cleanupError
        )
    }

    /// Finish a retirement whose cleanup could not complete inline.
    ///
    /// Detached and cancellation-safe on purpose: finalizing early would drop
    /// the reservation and let a new pane attach to the same target while the
    /// old gesture is still driving it, which is the interleaving the lane
    /// exists to prevent. Whoever holds the deferral can go away; this still
    /// runs to completion.
    private func deferTeardown(
        record: Record,
        mode: PaneCloseMode,
        actions: PaneCloseOutcome,
        externalCleanup: PaneExternalCleanup?
    ) {
        Task { [weak self] in
            await record.contactLane?.awaitIdle()
            await self?.tearDownRetiring(record: record, mode: mode)
            // Inside the reservation, deliberately. Waking a re-create at
            // backend teardown would let it attach and then be shut down by
            // this close's own pending `.shutdown`.
            _ = await externalCleanup?(actions)
            await self?.finalizeRetirement(record: record)
        }
    }

    /// Tear down a retired record's backend, retrying the held-contact release
    /// first on a detach.
    private func tearDownRetiring(record: Record, mode: PaneCloseMode) async {
        // A detach leaves the device running, so a contact the lane could not
        // free would still be down when something attaches next. Keep trying
        // rather than handing the target on dirty.
        //
        // A broken release reaches this loop only from the deferred task: the
        // inline path gets here having already released successfully. So the
        // retry never blocks the close RPC, the backend teardown, or the tunnel
        // release. The target stays reserved throughout, which is what actually
        // protects the next attach.
        if mode == .detach, let backend = record.backend {
            while await backend.releaseHeldContact() == false {
                // A cancelled sleep returns at once, so without this the retry
                // becomes a tight loop on the actor. Cancellation here means
                // the daemon is going away, which takes the device state with
                // it, so stop retrying and finish the teardown.
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .milliseconds(ContactLane.liveExpiryMs))
            }
        }
        let surfacePump = record.teardownSurfacePump()
        record.teardownOrientationPump(backend: record.backend)
        shutDownBackend(for: record)
        record.currentSurface = nil
        await surfacePump?.value
    }

    /// Stop the backend immediately, then release its cached AX bridge after
    /// every accessibility operation admitted before teardown has drained.
    /// A contact lane may retain the backend for held-contact recovery after a
    /// terminal transition, so relying on backend deinit would retain the AX
    /// delegate registration indefinitely.
    private func shutDownBackend(for record: Record) {
        guard let backend = record.backend else { return }
        backend.shutdownBackend()
        record.accessibilityWorkQueue.submit {
            backend.releaseAccessibilityResources()
        }
        record.backend = nil
    }

    /// Drop the retirement and let anything waiting on this target proceed.
    /// Runs once, after the external cleanup, so the device is genuinely free.
    private func finalizeRetirement(record: Record) {
        guard retiring.removeValue(forKey: record.id) != nil else { return }
        deferredCleanups -= 1
        resumeRetiringTargetWaiters(for: record.target)
    }

    /// Suspend until this retirement's backend teardown, external cleanup, and
    /// finalization have all completed.
    public func awaitDeferredTeardown(_ deferral: PaneCloseDeferral) async {
        guard retiring[deferral.paneId] != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            retirementWaiters.append((paneId: deferral.paneId, continuation: continuation))
        }
    }

    private func resumeRetiringTargetWaiters(for target: PaneTarget) {
        let matching = retirementWaiters.filter { retiring[$0.paneId] == nil }
        retirementWaiters.removeAll { retiring[$0.paneId] == nil }
        for waiter in matching {
            waiter.continuation.resume()
        }
        let targeted = retiringTargetWaiters.filter { $0.target == target }
        retiringTargetWaiters.removeAll { $0.target == target }
        for waiter in targeted {
            waiter.continuation.resume()
        }
    }

    /// Suspend while `target` is reserved by a retiring pane, so a re-create
    /// can't attach beside work that is still finishing.
    ///
    /// Its own waiter list rather than `awaitTransferSettled`, which applies to
    /// records still in `panes`.
    private func awaitRetiringTarget(_ target: PaneTarget) async {
        guard retiring.values.contains(where: { $0.target == target }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            retiringTargetWaiters.append((target: target, continuation: continuation))
        }
    }

    // MARK: - Display orientation

    /// Begin observing what this pane's display is presenting, and seed the
    /// record from it.
    ///
    /// Registers before seeding, so a rotation landing between the two
    /// arrives as a callback rather than disappearing into the gap between
    /// a snapshot and a subscription.
    ///
    /// A backend with no source (a physical device, the stub, or a display
    /// proxy that vends no orientation) leaves the record on its last known
    /// orientation and the pane keeps rendering. That is a degraded mode,
    /// not a failure: frames are untouched, and the pane still turns for
    /// rotations deviceterm commands itself.
    private func startDisplayOrientationObserver(
        record: Record,
        paneId: UUID,
        backend: DeviceBackend
    ) {
        // Stand the ordered pump up before starting observation: the
        // backend can deliver its first callback synchronously, so the
        // continuation has to exist first.
        let (stream, continuation) = AsyncStream.makeStream(
            of: Orientation.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        // Fenced on the observer's own epoch so a delivery still in flight
        // past teardown can't resurrect orientation state on a pane it no
        // longer describes.
        let observerEpoch = record.displayObserverEpoch
        let started = backend.startDisplayOrientation { orientation in
            continuation.yield(orientation)
        }
        guard started else {
            continuation.finish()
            return
        }
        record.observingDisplayOrientation = true
        record.orientationContinuation = continuation
        record.orientationPump = Task { [weak self, paneId] in
            for await orientation in stream {
                await self?.emitObservedOrientation(
                    paneId: paneId,
                    observerEpoch: observerEpoch,
                    orientation: orientation
                )
            }
        }
        if let seed = backend.currentDisplayOrientation() {
            record.presentationOrientation = seed
        }
    }

    /// Drop a callback delivered after observer teardown, and forward a
    /// live one for dedupe and publication. Unregistering can't recall a
    /// callback already dispatched on the queue, so the epoch check is what
    /// stops a late delivery changing the pane's presentation orientation.
    private func emitObservedOrientation(paneId: UUID, observerEpoch: UInt64, orientation: Orientation) {
        guard let record = panes[paneId],
            record.displayObserverEpoch == observerEpoch else { return }
        publishPresentationOrientation(record: record, paneId: paneId, orientation: orientation)
    }

    /// Commit a new presentation orientation and tell this pane's
    /// subscribers. Observed deliveries and the command-derived fallback
    /// both take this path. The observer's initial seed is assigned
    /// directly instead, since it runs before the pane has any subscribers
    /// to tell.
    ///
    /// Deduplicates repeated values of either kind: the bridge reports the
    /// current orientation after any screen-properties notification, not
    /// only a rotation, and a command can name the orientation the pane is
    /// already in.
    ///
    /// It is not what stops a commanded rotation emitting twice on an
    /// observing pane. `rotate` suppresses the command-derived path there
    /// outright, so only the observer publishes.
    private func publishPresentationOrientation(record: Record, paneId: UUID, orientation: Orientation) {
        guard record.presentationOrientation != orientation else { return }
        record.presentationOrientation = orientation
        for subscriber in record.subscribers.values {
            subscriber.continuation.yield(.orientationChanged(paneId: paneId, orientation: orientation))
        }
    }

    // MARK: - Input
    //
    // Backend resolution (`inputBackend`) is the actor's one stateful step;
    // the gesture coordinate/timing math and HID sends are pure and live in
    // `SimInputSynthesis`. `rotate` updates the pane's control orientation,
    // and publishes a presentation event only for a pane whose backend has
    // no display source to publish one instead.
    //
    // `inputBackend` also hands back the operation's input generation, which
    // then rides through the synthesis into every primitive. Its ordering
    // guarantee, and why the helper has the shape it does, is documented on
    // the helper itself.

    /// This pane's contact lane, built on first use.
    ///
    /// The recovery closure captures the backend rather than looking the pane
    /// up when it fires: a close removes the record from `panes` before the
    /// lane gets a chance to free an abandoned contact, so a lookup would find
    /// nothing and silently drop the lift. Every release joins the backend's
    /// ordered input queue before the lane admits the next gesture.
    private func lane(for record: Record, backend: any DeviceBackend) -> ContactLane {
        if let existing = record.contactLane { return existing }
        let lane = ContactLane { contact, generation in
            switch contact {
            case let .plain(point):
                return (try? await backend.tapUp(at: point, generation: generation)) != nil

            case let .edge(point, edge):
                return (try? await backend.edgeTouchUp(at: point, edge: edge, generation: generation)) != nil

            case let .multi(finger1, finger2):
                return (try? await backend.twoFingerUp(
                    f1: finger1,
                    f2: finger2,
                    generation: generation
                )) != nil

            case nil:
                // A composite that failed partway. It never told the lane what
                // it was holding, so the backend releases whatever it still
                // has down, matched to that contact's own kind.
                return await backend.releaseHeldContact()
            }
        }
        record.contactLane = lane
        return lane
    }

    /// Run a contact-holding gesture under the lane, releasing on every exit.
    ///
    /// Returns nil when the lane refused admission: the pane closed, it
    /// transferred, a held contact has not been recovered yet, or the caller's
    /// own task was cancelled while queued. A nil result means nothing was
    /// sent.
    private func withContactLane<T>(
        _ record: Record,
        backend: any DeviceBackend,
        preemptible: Bool,
        generation: UInt64,
        _ body: (GestureFence) async throws -> T
    ) async rethrows -> T? {
        let lane = lane(for: record, backend: backend)
        guard let ticket = await lane.admitComposite(preemptible: preemptible, generation: generation) else {
            return nil
        }
        // The cancellation handler races the handoff, so a request cancelled
        // while queued can still come back holding the lane. Give it back
        // before the first send rather than driving the device for a caller
        // that has gone away.
        if Task.isCancelled {
            await lane.release(ticket.id)
            return nil
        }
        do {
            let value = try await body(ticket.fence)
            await lane.release(ticket.id)
            return value
        } catch {
            // Unknown contact state: the terminal up may not have landed.
            await lane.releaseAfterFailure(ticket.id)
            throw error
        }
    }

    func tap(paneId: UUID, as principal: PaneAccessPrincipal, x: Double, y: Double) async throws {
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.touch,
            operation: .tap
        )
        // Not preemptible: the dwell is two frames, and cutting it short
        // reintroduces the contact too brief for a control to act on.
        try await withContactLane(
            input.record,
            backend: input.backend,
            preemptible: false,
            generation: input.generation
        ) { fence in
            try await SimInputSynthesis.tap(
                backend: input.backend,
                paneId: paneId,
                generation: input.generation,
                x: x,
                y: y,
                fence: fence
            )
        }
    }

    func touch(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        x: Double,
        y: Double,
        phase: TouchPhase
    ) async throws {
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.touch,
            operation: .touch
        )
        let lane = lane(for: input.record, backend: input.backend)
        let admitted = await lane.admitLive(
            phase: phase,
            contact: .plain(CGPoint(x: x, y: y)),
            generation: input.generation
        )
        guard admitted.send else { return }
        try await sendingLiveContact(admitted, on: lane) {
            try await SimInputSynthesis.touch(
                backend: input.backend,
                paneId: paneId,
                generation: input.generation,
                x: x,
                y: y,
                phase: phase
            )
        }
    }

    /// Perform a live contact send, then drop the lease if this phase ended the
    /// stream. Releasing first would let the next gesture's `down` reach the
    /// digitizer ahead of this `up`.
    private func sendingLiveContact(
        _ admitted: ContactLane.LiveAdmission,
        on lane: ContactLane,
        _ send: () async throws -> Void
    ) async rethrows {
        // Only a release that landed frees the lane. A failed lift leaves the
        // contact down, so the lease stays with it and the lane's expiry
        // synthesizes the release; dropping it here would admit the next
        // gesture on top of a finger that is still held.
        try await send()
        if let id = admitted.releaseAfterSend { await lane.release(id) }
    }

    func edgeTouch(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        x: Double,
        y: Double,
        phase: TouchPhase,
        edge: Int
    ) async throws {
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.touch,
            operation: .edgeTouch
        )
        let lane = lane(for: input.record, backend: input.backend)
        let admitted = await lane.admitLive(
            phase: phase,
            contact: .edge(CGPoint(x: x, y: y), edge: edge),
            generation: input.generation
        )
        guard admitted.send else { return }
        try await sendingLiveContact(admitted, on: lane) {
            try await SimInputSynthesis.edgeTouch(
                backend: input.backend,
                paneId: paneId,
                generation: input.generation,
                x: x,
                y: y,
                phase: phase,
                edge: edge
            )
        }
    }

    func swipe(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int,
        holdMs: Int = 0,
        startHoldMs: Int = 0
    ) async throws -> SwipeOutcome {
        // Capture the backend locally before any await so a concurrent
        // `close` can't yank it mid-swipe.
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.touch,
            operation: .swipe
        )
        let outcome = try await withContactLane(
            input.record,
            backend: input.backend,
            preemptible: true,
            generation: input.generation
        ) { fence in
            try await SimInputSynthesis.swipe(
                backend: input.backend,
                paneId: paneId,
                generation: input.generation,
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY,
                durationMs: durationMs,
                holdMs: holdMs,
                startHoldMs: startHoldMs,
                fence: fence
            )
        }
        // Refused admission means nothing went out, which is a zero-sample
        // gesture rather than a failure. The ack reports it as a tap.
        return outcome ?? SwipeOutcome(
            steps: 0,
            durationMs: GestureTiming(durationMs: durationMs, maxMs: Self.maxGestureDurationMs).totalMs
        )
    }

    func edgeSwipe(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        edge: Int,
        durationMs: Int,
        holdMs: Int
    ) async throws {
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.touch,
            operation: .edgeSwipe
        )
        // On a sim this is an interpolated drag and preemptible like any
        // other. On a device it realizes as the App Switcher macro, which only
        // reads as a gesture whole, so live input waits it out instead.
        let preemptible = input.backend.supportsSystemEdgeGesture
        try await withContactLane(
            input.record,
            backend: input.backend,
            preemptible: preemptible,
            generation: input.generation
        ) { fence in
            try await SimInputSynthesis.edgeSwipe(
                backend: input.backend,
                paneId: paneId,
                generation: input.generation,
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY,
                edge: edge,
                durationMs: durationMs,
                holdMs: holdMs,
                fence: fence
            )
        }
    }

    func longPress(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        x: Double,
        y: Double,
        durationMs: Int
    ) async throws {
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.touch,
            operation: .longPress
        )
        try await withContactLane(
            input.record,
            backend: input.backend,
            preemptible: true,
            generation: input.generation
        ) { fence in
            try await SimInputSynthesis.longPress(
                backend: input.backend,
                paneId: paneId,
                generation: input.generation,
                x: x,
                y: y,
                durationMs: durationMs,
                fence: fence
            )
        }
    }

    func key(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        keyCode: UInt32,
        down: Bool
    ) async throws {
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.key,
            operation: .key(down: down)
        )
        try await SimInputSynthesis.key(
            backend: input.backend,
            paneId: paneId,
            generation: input.generation,
            keyCode: keyCode,
            down: down
        )
    }

    func pressButton(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        button: HardwareButton
    ) async throws {
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.button,
            operation: .button(button)
        )
        try await SimInputSynthesis.pressButton(
            backend: input.backend,
            paneId: paneId,
            generation: input.generation,
            button: button
        )
    }

    func pinch(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        fromF1X: Double,
        fromF1Y: Double,
        fromF2X: Double,
        fromF2Y: Double,
        toF1X: Double,
        toF1Y: Double,
        toF2X: Double,
        toF2Y: Double,
        durationMs: Int
    ) async throws {
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.touch,
            operation: .pinch
        )
        try await withContactLane(
            input.record,
            backend: input.backend,
            preemptible: true,
            generation: input.generation
        ) { fence in
            try await SimInputSynthesis.pinch(
                backend: input.backend,
                paneId: paneId,
                generation: input.generation,
                fromF1X: fromF1X,
                fromF1Y: fromF1Y,
                fromF2X: fromF2X,
                fromF2Y: fromF2Y,
                toF1X: toF1X,
                toF1Y: toF1Y,
                toF2X: toF2X,
                toF2Y: toF2Y,
                durationMs: durationMs,
                fence: fence
            )
        }
    }

    func multitouch(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        phase: TouchPhase,
        points: [CGPoint]
    ) async throws {
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.touch,
            operation: .multitouch
        )
        // The synthesis rejects any other count, so a well-formed frame always
        // has two contacts to name in the lease.
        guard points.count == 2 else {
            // The synthesis rejects any other count with a bridge error; let it
            // report that rather than admitting a frame the lane can't name.
            try await SimInputSynthesis.multitouch(
                backend: input.backend,
                paneId: paneId,
                generation: input.generation,
                phase: phase,
                points: points
            )
            return
        }
        let lane = lane(for: input.record, backend: input.backend)
        let admitted = await lane.admitLive(
            phase: phase,
            contact: .multi(points[0], points[1]),
            generation: input.generation
        )
        guard admitted.send else { return }
        try await sendingLiveContact(admitted, on: lane) {
            try await SimInputSynthesis.multitouch(
                backend: input.backend,
                paneId: paneId,
                generation: input.generation,
                phase: phase,
                points: points
            )
        }
    }

    func text(paneId: UUID, as principal: PaneAccessPrincipal, text: String) async throws {
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.text,
            operation: .text
        )
        try await SimInputSynthesis.text(
            backend: input.backend,
            paneId: paneId,
            generation: input.generation,
            text: text
        )
    }

    func rotate(paneId: UUID, as principal: PaneAccessPrincipal, target: RotationTarget) async throws {
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.rotate,
            operation: .rotate
        )
        // Serialize this pane's rotations end-to-end so their broadcasts stay
        // in request order. This prefix runs with no `await`, so installing the
        // new tail is atomic on the actor; the next rotation then awaits *this*
        // link. Signalled on every exit (defer), so a skip or throw can't wedge
        // the chain. `await`/`signal` are actor-isolated (below), so no wakeup
        // is lost between a link's `done` check and its continuation register.
        let record = input.record
        let priorRotation = record.rotationTail
        let thisRotation = SerialChainLink()
        record.rotationTail = thisRotation
        defer { signalChainLink(thisRotation) }
        if let priorRotation { await awaitChainLink(priorRotation) }
        // Resolve a direction only now that the predecessor has finished and
        // committed its own orientation. Reading the tracked value before the
        // await would give two concurrent `left` requests the same base, so
        // both would pick the same destination and one 90° step would vanish.
        let orientation: Orientation
        switch target {
        case let .absolute(value):
            orientation = value

        case let .relative(direction):
            orientation = direction.applied(to: record.controlOrientation)
        }
        let performed = try await SimInputSynthesis.rotate(
            backend: input.backend,
            paneId: paneId,
            generation: input.generation,
            orientation: orientation
        )
        guard performed else { return }
        // Commit the new base for the next relative request. The chain link
        // this rotation holds is signalled after it (on scope exit), so the
        // successor resolves against it.
        //
        record.controlOrientation = orientation
        // For a pane that is observing its display, the command stops here
        // and publishes nothing: it says where the device was told to point,
        // never what the display did, and an orientation-locked app answers
        // a rotate by leaving the framebuffer where it was. Observation
        // publishes instead, so the pane turns when the pixels turn.
        //
        // A pane with no display-orientation source has no such observation
        // coming, so the command is the only evidence available and it
        // publishes. That preserves command-driven rotation for
        // non-observing backends; an orientation-locked interface stays
        // unobservable to them.
        guard !record.observingDisplayOrientation else { return }
        publishPresentationOrientation(record: record, paneId: paneId, orientation: orientation)
    }

    /// Suspend until `link` is signalled (returns immediately if it already
    /// was). Actor-isolated: the `done` check and the continuation register run
    /// with no suspension between them, and `signalChainLink` (also
    /// actor-isolated) cannot interleave, so the wakeup is never lost.
    private func awaitChainLink(_ link: SerialChainLink) async {
        if link.done { return }
        await withCheckedContinuation { link.waiter = $0 }
    }

    /// Mark `link` done and resume the next rotation waiting on it. Idempotent,
    /// so the rotate `defer` can call it on every exit path (success, skip,
    /// throw) without wedging the chain.
    private func signalChainLink(_ link: SerialChainLink) {
        guard !link.done else { return }
        link.done = true
        link.waiter?.resume()
        link.waiter = nil
    }

    func crown(paneId: UUID, as principal: PaneAccessPrincipal, delta: Double, durationMs: Int) async throws {
        // Capture the backend before any await so a concurrent `close`
        // can't yank it mid-rotation.
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.crown,
            operation: .crown
        )
        try await SimInputSynthesis.crown(
            backend: input.backend,
            paneId: paneId,
            generation: input.generation,
            delta: delta,
            durationMs: durationMs
        )
    }

    // MARK: - Accessibility
    //
    // As with input, backend resolution is the actor's only stateful step
    // (`accessibilityTree` also reads the pane's immutable `family`). The
    // bridge read + `AXTreeAnnotator`/`AXSweep` post-processing + JSON
    // serialization are pure and live in `PaneAccessibility`; the bridge's
    // non-Sendable Foundation dicts never escape it, only `Data`. Each read
    // re-authorizes after its off-pool suspension so a session cannot receive
    // a result after the pane closes, transfers away, or reaches a terminal
    // lifecycle while its record remains available for the GUI overlay.

    func accessibilityTree(paneId: UUID, as principal: PaneAccessPrincipal) async throws -> Data {
        // `requireBackend` authorizes ownership and hands back the record,
        // so the family read below is a single authorized lookup; no
        // second unauthorized `panes[paneId]` read. Unknown family safely
        // falls through `AXTreeAnnotator` without annotation.
        let (record, backend) = try requireBackend(
            paneId: paneId,
            as: principal,
            supporting: \.accessibility,
            operation: .axTree
        )
        let family = DeviceFamily(rawValue: record.family) ?? .unknown
        let data = try await PaneAccessibility.tree(
            backend: backend,
            queue: record.accessibilityWorkQueue,
            paneId: paneId,
            family: family
        )
        try revalidateAccessibility(
            record: record,
            backend: backend,
            paneId: paneId,
            as: principal
        )
        return data
    }

    func accessibilityElement(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        x: Double,
        y: Double
    ) async throws -> Data {
        let (record, backend) = try requireBackend(
            paneId: paneId,
            as: principal,
            supporting: \.accessibility,
            operation: .axPoint
        )
        let data = try await PaneAccessibility.element(
            backend: backend,
            queue: record.accessibilityWorkQueue,
            paneId: paneId,
            x: x,
            y: y
        )
        try revalidateAccessibility(
            record: record,
            backend: backend,
            paneId: paneId,
            as: principal
        )
        return data
    }

    func accessibilitySweep(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        step: Double?
    ) async throws -> Data {
        let (record, backend) = try requireBackend(
            paneId: paneId,
            as: principal,
            supporting: \.accessibility,
            operation: .axSweep
        )
        let data = try await PaneAccessibility.sweep(
            backend: backend,
            queue: record.accessibilityWorkQueue,
            paneId: paneId,
            step: step
        )
        try revalidateAccessibility(
            record: record,
            backend: backend,
            paneId: paneId,
            as: principal
        )
        return data
    }

    /// Fence a completed AX payload against the exact pane record and backend
    /// that produced it. Terminal shutdown/failure retains the record but
    /// clears its backend; ownership-only authorization therefore is not a
    /// sufficient post-suspension check.
    private func revalidateAccessibility(
        record: Record,
        backend: any DeviceBackend,
        paneId: UUID,
        as principal: PaneAccessPrincipal
    ) throws {
        let current = try authorize(paneId: paneId, as: principal, gatesInput: false)
        guard current === record else {
            throw PaneError.notFound(paneId: paneId)
        }
        guard let currentBackend = current.backend,
            ObjectIdentifier(currentBackend) == ObjectIdentifier(backend),
            current.state != .shutdown,
            current.state != .failed else {
            throw PaneError.paneNotActive(paneId: paneId)
        }
    }

    // MARK: - Location
    //
    // Both entry points suspend across a backend call (a physical device
    // shells out to `devicectl`), and this actor is **reentrant** across
    // suspension: another entry point can close, shut down, or transfer
    // the pane while a location call is in flight. So neither may touch
    // `panes` or a `Record` after an `await` without re-fencing first.
    // The two need *different* fences, because they are asking different
    // questions:
    //
    //   - `locationState` is a read answering a principal, so it
    //     re-`authorize`s: a `.session` caller must not be told about a
    //     pane that transferred away from it mid-read.
    //   - `setLocation` has already acted on the device; its remaining
    //     question is only whether the claim still describes this pane,
    //     so it validates record identity plus `locationEpoch`.
    //     Re-authorizing there would be wrong. See the note at its
    //     commit fence.

    /// Apply a simulated position to the pane's device and record it as
    /// what deviceterm last set.
    ///
    /// The tracked value moves **only after** the backend call returns,
    /// so a failed set never moves the menu's checkmark onto a location
    /// the device never took.
    ///
    /// Two orderings have to hold for the claim to mean anything, and
    /// neither is free:
    ///
    /// 1. **Commands serialize per pane**, through this record's location
    ///    chain, exactly as rotations do. Each command suspends on a
    ///    backend call, and independent continuations aren't guaranteed to
    ///    resume in issue order, so two overlapping sets could otherwise
    ///    leave the device at one location and the claim at the other.
    /// 2. **The commit is fenced on `locationEpoch`**, snapshotted at
    ///    admission. Re-authorizing is *not* enough here: location runs
    ///    as `.guiPeer`, which `authorize` admits for any live record, so
    ///    a set issued before an ownership transfer would sail through
    ///    the post-`await` check and re-stamp a claim onto a pane the
    ///    transfer had just dropped one from. `locationEpoch` advances on
    ///    exactly the events that drop the claim, and, unlike `epoch`,
    ///    not on a transfer that starts and then aborts, so a command
    ///    that did reach the device still records.
    func setLocation(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        to location: SimulatedLocation
    ) async throws {
        // The generation comes back captured at admission, before any
        // suspension. If a transfer advances the backend before this command
        // is sent, the generation fence each backend applies rejects it. If
        // the command already ran, the location-epoch check below stops its
        // now-stale claim from being committed after the transfer.
        let input = try inputBackend(
            paneId: paneId,
            as: principal,
            supporting: \.location,
            operation: .locationSet
        )
        let record = input.record
        let backend = input.backend
        let admittedLocationEpoch = record.locationEpoch

        // Take this pane's location slot. The prefix runs with no `await`,
        // so installing the new tail is atomic on the actor; signalled on
        // every exit path (success, throw, or early return) so a failure
        // can't wedge the chain.
        let priorLocation = record.locationTail
        let thisLocation = SerialChainLink()
        record.locationTail = thisLocation
        defer { signalChainLink(thisLocation) }
        if let priorLocation { await awaitChainLink(priorLocation) }

        do {
            switch location {
            case .cleared:
                try await backend.clearSimulatedLocation(generation: input.generation)

            case let .coordinate(latitude, longitude):
                try await backend.setSimulatedLocation(
                    latitude: latitude,
                    longitude: longitude,
                    generation: input.generation
                )

            case let .scenario(name):
                try await backend.setSimulatedLocationScenario(name, generation: input.generation)

            case let .route(spec):
                try await backend.startSimulatedLocationRoute(spec, generation: input.generation)
            }
        } catch let error as DeviceBackendError {
            throw PaneError.mapBackendError(error, paneId: paneId, operation: .locationSet)
        } catch {
            // The CoreSimulator setters throw raw bridge `NSError`s, which
            // are not `DeviceBackendError`. Without this arm they escape
            // the typed mapping entirely and reach the wire as the
            // catch-all `serverError` instead of `bridgeFailed`, so a
            // machine consumer can't tell "the bridge spoke up" from any
            // other server-side failure. Same two-arm shape the input
            // synthesis helpers use.
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .locationSet,
                message: BridgeMessage.unwrap(error)
            )
        }
        // Commit fence. The record must still be the same live instance it
        // was at admission, at the same location epoch: a close removed
        // it, and a committed transfer / shutdown / failure already reset
        // the claim, so writing here would resurrect a checkmark for a
        // pane that has moved on. The device took the position either way,
        // so a dropped stamp is an untracked write, not an error.
        //
        // Deliberately **not** a re-`authorize` (unlike `locationState`,
        // which is a read answering a principal and must re-check). The
        // question here isn't "may this caller still act", which was
        // settled at admission and the device has already moved on, but
        // "is the claim still about this pane". Re-authorizing would also
        // reintroduce the aborted-transfer bug: `gatesInput: true` denies
        // every principal while `transferring` is set, so a set that
        // landed during a transfer which then aborted would lose its
        // claim even though ownership never moved.
        guard panes[paneId] === record,
            record.locationEpoch == admittedLocationEpoch else { return }
        record.simulatedLocation = location
    }

    /// What deviceterm last applied to this pane, plus the scenarios its
    /// device offers.
    ///
    /// `gatesInput: false`: this is a read, and it must answer for a
    /// `.shutdown` pane whose backend is gone rather than faulting. The
    /// GUI builds its menu from this, and a menu that throws is worse
    /// than one that reports nothing set.
    ///
    /// A failed enumeration degrades to an empty scenario list rather
    /// than throwing. Empty is already the honest answer for a device
    /// that isn't running (a simulator vends no scenarios until booted),
    /// and a device that won't answer is operationally the same case.
    /// Degrading keeps the read total, so the tracked location, the part
    /// the daemon always knows, still reaches the caller instead of being
    /// lost to a transient `devicectl` failure. The *set* path still
    /// throws, which is where silence would cost something.
    func locationState(
        paneId: UUID,
        as principal: PaneAccessPrincipal
    ) async throws -> PaneLocationStateResult {
        let record = try authorize(paneId: paneId, as: principal, gatesInput: false)
        guard let backend = record.backend, backend.capabilities.location else {
            return PaneLocationStateResult(location: record.simulatedLocation, scenarios: [])
        }
        let admittedLocationEpoch = record.locationEpoch
        let scenarios = await enumerateScenarios(backend: backend, paneId: paneId)
        // Post-`await` **re-authorization**, per the section note: a
        // `.session` principal that passed the gate before this suspension
        // must not be answered once the pane has transferred away from it,
        // or while a transfer is in flight. Identity is checked alongside
        // it because a close removes the record outright.
        guard let current = try? authorize(paneId: paneId, as: principal, gatesInput: false),
            current === record else {
            throw PaneError.notFound(paneId: paneId)
        }
        // Discard an enumeration that raced a teardown. A shutdown or
        // failure keeps the *same* `Record` while clearing its backend and
        // dropping the claim, so identity alone still matches. Pairing a
        // now-absent claim with trips read from the retired backend would
        // offer the user scenarios that can no longer be applied, and
        // contradict this method's documented "empty for a device that
        // isn't running". Dropping them is enough: whatever the daemon
        // still knows goes back, and the next menu open re-reads against
        // whatever backend exists then.
        let live = current.locationEpoch == admittedLocationEpoch ? scenarios : []
        return PaneLocationStateResult(location: current.simulatedLocation, scenarios: live)
    }

    /// Enumerate a backend's scenarios, degrading to an empty list but
    /// **never silently** on a structural failure.
    ///
    /// The read has to stay total, because the GUI builds a menu from it
    /// and a menu that throws is worse than one offering no trips, so
    /// every failure ends up as `[]`. That is a hazard for exactly one
    /// failure kind: if the tool's output schema drifts, every device
    /// reports no trips, indistinguishable from a device that isn't
    /// running.
    ///
    /// So the two are logged differently. An unreachable or not-running
    /// device is routine and stays at debug, while unintelligible output
    /// is an error-level complaint naming the pane, keeping schema
    /// mismatches observable. Nothing is thrown in either case.
    private func enumerateScenarios(
        backend: any DeviceBackend,
        paneId: UUID
    ) async -> [String] {
        do {
            return try await backend.availableLocationScenarios()
        } catch let DeviceBackendError.locationOutputMalformed(message) {
            locationLog.error(
                """
                pane \(paneId.uuidString, privacy: .public): location scenario output was \
                unreadable (\(message, privacy: .public)). Reporting no trips; this is a \
                schema mismatch, not an idle device.
                """
            )
        } catch {
            // Routine: a device that isn't running enumerates nothing.
            locationLog.debug(
                """
                pane \(paneId.uuidString, privacy: .public): no location scenarios \
                (\(String(describing: error), privacy: .public))
                """
            )
        }
        return []
    }

    // MARK: - Query

    /// Attribution and controller membership for every live pane, keyed by
    /// device target. Backs the `devices.list` roster's attachment
    /// annotation, which then applies protected-tab opacity on the returned
    /// session ids. Includes shutdown/failed records so a device the GUI
    /// still shows a (dead) pane for reads as attached.
    ///
    /// Reports **every** session that may drive the pane, not just the record's
    /// own. The roster tests "can the caller see any of these", and a caller
    /// that shares a protected tab with the attaching terminal cannot see that
    /// terminal's session: `SessionManager.sessions(visibleTo:)` is per-session
    /// with no grouping, so a protected sibling would read its own tab's device
    /// as unattached.
    public func liveOwnerships() -> [PaneOwnership] {
        panes.values.map {
            PaneOwnership(
                target: $0.target,
                sessionId: attributedSession(of: $0),
                paneShortId: $0.shortId,
                paneId: $0.id,
                controllingMembers: controllers(of: $0)
            )
        }
    }

    /// The sessions permitted to drive `record`: its cohort's members, or just
    /// its own session when it has none. A record naming a cohort that cannot
    /// be resolved reports none, matching `cohortAdmits`.
    private func controllers(of record: Record) -> Set<CohortMember> {
        switch resolveCohort(record.cohortId) {
        case .unbound:
            return [
                CohortMember(
                    sessionId: record.sessionId,
                    incarnation: record.acceptedIncarnation ?? 0
                )
            ]

        case let .live(members, _):
            return Set(members)

        case .denied:
            return []
        }
    }

    /// The session a cohort-bound pane is *attributed* to, which is its
    /// cohort's representative rather than whichever session happened to
    /// attach it. Keeping one source for this is what stops `ownerSessionId`
    /// drifting after the daemon reattributes a representative the GUI has
    /// not reconciled yet.
    private func attributedSession(of record: Record) -> UUID {
        guard let cohortId = record.cohortId,
            case let .live(_, representative) = resolveCohort(cohortId) else { return record.sessionId }
        return representative
    }

    /// Panes a session may drive, which backs `panes.list` and the CLI's
    /// pane resolution. Every pane's identity is reported via its target key
    /// (a sim UDID or a physical device id). Sorted by paneId for stable
    /// output.
    ///
    /// Cohort-scoped, so a sibling terminal sees the tab's panes rather than an
    /// empty list. This is the discovery half of tab-scoped control: without
    /// it a sibling could drive a pane it had no way to name.
    public func panesForSession(_ sessionId: UUID, incarnation: UInt64? = nil) -> [PaneInfo] {
        panes.values
            .filter { cohortAdmits(record: $0, sessionId: sessionId, requestIncarnation: incarnation) }
            .map { PaneInfo(
                paneId: $0.id,
                udid: $0.target.key,
                state: $0.state,
                family: $0.family,
                shortId: $0.shortId,
                name: $0.name,
                capabilities: $0.capabilities,
                target: $0.target
            )
            }
            .sorted { $0.paneId.uuidString < $1.paneId.uuidString }
    }

    // MARK: - Bridge callback (private)

    /// Commit one retained frame without suspending the coordinator. The
    /// ordered per-pane pump awaits the returned broker and side-band fan-out,
    /// so this actor handles one bounded mailbox turn per frame rather than
    /// leaving a frame task to resume here after each cross-actor hop.
    private func handleSurfaceCallback(
        paneId: UUID,
        published: PublishedSurface
    ) -> SurfacePublishWork? {
        guard let record = panes[paneId], record.state == .booting || record.state == .rendering else {
            return nil
        }
        // Sequence: a leased (device) frame carries its pool generation
        // (per-pane monotonic and never repeating) and is dropped if it
        // would not advance the sequence (defensive against an out-of-order
        // arrival). A sim frame keeps the plain incrementing counter.
        let sequence: UInt64
        if let lease = published.lease {
            guard lease.generation > record.lastSequence else { return nil }
            sequence = lease.generation
        } else {
            sequence = record.lastSequence &+ 1
        }
        record.lastSequence = sequence
        record.currentSurface = published
        // Off-by-default producer trace row (paneId is known here, not at
        // the copy site). Joined offline with the GUI consumer row by
        // (paneId, traceId).
        if let trace = published.trace {
            SurfaceTraceSink.daemonProducer?.record(
                SurfaceTraceRow(
                    role: "producer",
                    paneId: paneId.uuidString,
                    traceId: trace.traceId,
                    monotonicNanoseconds: trace.producedAtNanoseconds,
                    mismatchRows: nil
                )
            )
        }
        // First surface = transition out of booting.
        let statePublication: SurfacePublishWork.StatePublication?
        if record.state == .booting {
            record.state = .rendering
            for (_, subscriber) in record.subscribers {
                subscriber.continuation.yield(.stateChanged(paneId: paneId, state: .rendering))
            }
            // Publish the booting→rendering transition to the event
            // stream, scoped to the sessions permitted to drive the
            // pane. Boot-wait
            // callers (`deviceterm events | jq 'select(.state=="rendering")'`)
            // pick up here.
            statePublication = SurfacePublishWork.StatePublication(
                paneId: paneId,
                epoch: record.epoch,
                event: .paneStateChanged(
                    paneId: paneId.uuidString,
                    udid: record.target.key,
                    state: PaneLifecycle.rendering.rawValue
                ),
                audience: .sessions(controllers(of: record))
            )
        } else {
            statePublication = nil
        }
        // JSON evt path: yield to the per-record subscribers map
        // (the existing UDS fan-out). The same yield drives the
        // PaneMethods.subscribe adapter that emits the wire-level
        // `surface.changed` payload: JSON only.
        for (_, subscriber) in record.subscribers {
            subscriber.continuation.yield(.surfaceChanged(paneId: paneId, sequence: sequence))
        }
        // The ordered pump handles the cross-actor side-band path after this
        // turn. UDS subscribers have no delivery handle registered, so the
        // registry's per-`(paneId, connectionId)` slot stays empty for them.
        return SurfacePublishWork(
            paneId: paneId,
            published: published,
            sequence: sequence,
            statePublication: statePublication
        )
    }

    /// Publish the first-frame lifecycle event only if the record still holds
    /// the state and ownership epoch committed with that frame. Once admitted,
    /// terminal teardown joins the surface pump and session revocation waits on
    /// `surfaceStatePublicationInFlight`, so neither terminal event can
    /// overtake this publication.
    private func publishSurfaceStateIfCurrent(
        _ publication: SurfacePublishWork.StatePublication
    ) async {
        guard let record = panes[publication.paneId],
            record.epoch == publication.epoch,
            record.state == .rendering,
            !record.ownerRevoked,
            !record.transferring else { return }

        record.surfaceStatePublicationInFlight = true
        await eventBroker?.publish(publication.event, to: publication.audience)
        record.surfaceStatePublicationInFlight = false
        let waiters = record.surfaceStatePublicationWaiters
        record.surfaceStatePublicationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Wait until an admitted first-frame state publication has completed.
    /// Used by session revocation before it allows `.sessionClosed` to publish.
    private func awaitSurfaceStatePublication(_ record: Record) async {
        guard record.surfaceStatePublicationInFlight else { return }
        await withCheckedContinuation { record.surfaceStatePublicationWaiters.append($0) }
    }

    /// Release session revocation after the winning terminal transition has
    /// published, or after a close removed the record before it could publish.
    /// A superseded transition cannot clear the newer transition's barrier.
    private func finishTerminalStatePublication(_ record: Record, revision: UInt64) {
        guard record.terminalPublicationRevision == revision else { return }
        record.terminalStatePublicationInFlight = false
        let waiters = record.terminalStatePublicationWaiters
        record.terminalStatePublicationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Keep `.sessionClosed` behind a terminal pane event that was already
    /// committed when the session's subscription sweep began.
    private func awaitTerminalStatePublication(_ record: Record) async {
        guard record.terminalStatePublicationInFlight else { return }
        await withCheckedContinuation { record.terminalStatePublicationWaiters.append($0) }
    }

    // MARK: - Helpers

    /// Ownership gate for every pane-targeted operation. A `.session`
    /// principal reaches an unbound pane owned by that session, or a
    /// cohort-bound pane whose membership contains its session (matched on
    /// incarnation too when the request carries a pin); the validated
    /// `.guiPeer` spans every session. Returns the authorized record.
    ///
    /// A pane that does not exist and a pane owned by another session
    /// throw the **same** `notFound`; a distinct "forbidden" result
    /// would itself be an existence oracle for pane UUIDs (the caller is
    /// same-user and could otherwise probe which random UUIDs name a
    /// real, live, other-session pane).
    ///
    /// While a record is mid-`transferring`, ownership is in flux, so the
    /// gate denies to keep the transfer's quiesced window airtight: a
    /// `.session` principal is denied for every operation; `.guiPeer` is
    /// denied *input/backend* operations (`gatesInput: true`) so no input
    /// enqueues into a generation being torn down, but is allowed
    /// *presentation* (`gatesInput: false`, e.g. the subscribe read path)
    /// so the GUI keeps rendering across the brief transfer.
    private func authorize(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        gatesInput: Bool
    ) throws -> Record {
        guard let record = panes[paneId] else {
            throw PaneError.notFound(paneId: paneId)
        }
        switch principal {
        case .guiPeer:
            if record.transferring, gatesInput {
                throw PaneError.notFound(paneId: paneId)
            }
            return record

        case let .session(sessionId, requestIncarnation):
            // No active transfer, no owner revocation, and matching
            // incarnations when both sides carry one. A pane whose session was
            // closed (subscriptions swept) stays unreachable to `.session`
            // principals until re-owned, so a subscribe that slipped past the
            // dispatch scope check and resumed post-close mints nothing; and a
            // request authorized under one incarnation can't reach a pane
            // re-owned by the same UUID at a different incarnation.
            guard !record.transferring,
                !record.ownerRevoked,
                cohortAdmits(
                    record: record,
                    sessionId: sessionId,
                    requestIncarnation: requestIncarnation
                ) else {
                throw PaneError.notFound(paneId: paneId)
            }
            return record
        }
    }

    /// Test-only: the panes currently bound to a cohort.
    func panesBound(toCohort cohortId: UUID) -> [UUID] {
        panes.values.filter { $0.cohortId == cohortId }.map(\.id)
    }

    /// The cohort a record names, as of now.
    private func resolveCohort(_ cohortId: UUID?) -> CohortResolution {
        cohortState.resolve(cohortId: cohortId)
    }

    /// Whether `sessionId` is permitted to drive `record`, which is a
    /// three-state question and not a two-state one:
    ///
    /// | `record.cohortId` | admits |
    /// |---|---|
    /// | nil | the record's own `sessionId`, the compatibility fallback |
    /// | an installed cohort | that cohort's members |
    /// | a retired or never-installed cohort | nobody |
    ///
    /// Keep the third row distinct from unbound, so a missing cohort never
    /// falls back to the record's own session. Writing this as "members if
    /// we have them, else the owner" would collapse it into the first row
    /// the moment a cohort was retired or a replacement rejected. A pane in the third row is
    /// driven by nobody and still rendered by the GUI, the same shape an
    /// orphan already has.
    private func cohortAdmits(
        record: Record,
        sessionId: UUID,
        requestIncarnation: UInt64?
    ) -> Bool {
        guard let cohortId = record.cohortId else {
            return record.sessionId == sessionId
                && incarnationAdmits(record: record, requestIncarnation: requestIncarnation)
        }
        guard case let .live(members, _) = resolveCohort(cohortId),
            let member = members.first(where: { $0.sessionId == sessionId }) else {
            return false
        }
        // The ABA gate for a cohort-bound pane is the MEMBER'S own incarnation,
        // not the pane creator's. `acceptedIncarnation` records whichever
        // session attached the device, and incarnations are daemon-global, so
        // judging a sibling against it rejects every session in the cohort
        // except the one that happened to attach. The cohort already carries a
        // verified incarnation per member, which is the value a restored
        // same-UUID session must fail against.
        guard let requestIncarnation else { return true }
        return member.incarnation == requestIncarnation
    }

    /// Test-only: ask the ownership gate the question every input and AX
    /// handler asks it, without needing a backend to drive.
    func canSessionDrive(paneId: UUID, session: UUID, incarnation: UInt64?) -> Bool {
        (try? authorize(
            paneId: paneId,
            as: .session(session, incarnation: incarnation),
            gatesInput: false
        )) != nil
    }

    /// Install or replace a cohort, binding pane records in the same turn.
    ///
    /// The whole transition commits synchronously: liveness is a local read,
    /// binding feasibility is checked before anything mutates, and membership
    /// and bindings land together, with no window between deciding and
    /// committing for a competing transition to occupy. The suspensions
    /// below the commit only tear down streams whose authorization the
    /// commit already withdrew.
    func reconcileCohort(
        cohortId: UUID,
        members: [CohortMember],
        representative: UUID,
        replaces: UUID?,
        requested: [SessionCohortBinding],
        key: ProtectionOrderingKey
    ) async -> CohortTransition {
        let isReplacement = replaces != nil && replaces != cohortId
        var planned: [(paneId: UUID, attachment: UInt64)] = []
        var malformed: [SessionCohortBindingResult] = []
        var seen: Set<UUID> = []
        for binding in requested {
            guard let paneId = UUID(uuidString: binding.paneId) else {
                malformed.append(SessionCohortBindingResult(paneId: binding.paneId, bound: false))
                continue
            }
            seen.insert(paneId)
            planned.append((paneId: paneId, attachment: binding.expectedAttachment))
        }
        // A replacement sweeps every pane still naming the outgoing cohort, not
        // just the ones the request listed: the GUI's snapshot can be missing a
        // pane that attached while the reconcile was in flight, and leaving one
        // behind strands it naming a cohort that no longer exists.
        if let replaces, isReplacement {
            for record in panes.values where record.cohortId == replaces && !seen.contains(record.id) {
                planned.append((paneId: record.id, attachment: record.attachment))
            }
        }
        // The cross-cohort fence. A binding may take a pane that is unbound,
        // already this cohort's, or inherited from the cohort this request
        // replaces, never one a different live cohort holds: a move between
        // live cohorts must replace or retire the current cohort first. The
        // attachment cannot fence it, because binding does not advance the
        // attachment, so a delayed reconcile for cohort A, ordered only
        // against A's own key, would otherwise pass both checks and steal
        // back a pane a newer reconcile had just bound elsewhere.
        func bindable(_ record: Record) -> Bool {
            record.cohortId == nil || record.cohortId == cohortId || record.cohortId == replaces
        }
        let feasible = malformed.isEmpty && planned.allSatisfy { plan in
            guard let record = panes[plan.paneId] else { return false }
            return record.attachment == plan.attachment && bindable(record)
        }
        var transition = cohortState.reconcile(
            cohortId: cohortId,
            members: members,
            representative: representative,
            replaces: replaces,
            key: key,
            isLive: { [activeIncarnation] member in
                activeIncarnation[member.sessionId] == member.incarnation
            },
            bindingsSucceed: feasible
        )
        guard transition.applied else {
            transition.bindings = malformed + planned.map {
                SessionCohortBindingResult(paneId: $0.paneId.uuidString, bound: false)
            }
            return transition
        }
        var results = malformed
        for plan in planned {
            guard let record = panes[plan.paneId], record.attachment == plan.attachment,
                bindable(record) else {
                results.append(SessionCohortBindingResult(paneId: plan.paneId.uuidString, bound: false))
                continue
            }
            record.cohortId = cohortId
            results.append(SessionCohortBindingResult(paneId: plan.paneId.uuidString, bound: true))
        }
        transition.bindings = results
        // A removed member is still alive, so its panes change hands as a
        // targeted transfer rather than a close: re-home the records it owns
        // in this cohort to the incoming representative, and tell the device
        // layer to move exactly those devices and their matching boot claims.
        // No tombstone and no wider sweep; its unrelated devices and late
        // claims stay its own.
        if let successorMember = members.first(where: { $0.sessionId == representative }) {
            for dropped in transition.removed where dropped.sessionId != successorMember.sessionId {
                let moved = rehome(from: dropped.sessionId, to: successorMember, cohortId: cohortId)
                guard !moved.isEmpty else { continue }
                emit(
                    .transfer(
                        CohortTransferEffect(
                            previousOwner: dropped,
                            successor: successorMember,
                            targets: moved
                        )
                    )
                )
            }
        }
        await sweepNonMemberSubscribers(cohortId: cohortId)
        return transition
    }

    /// Restore the subscription invariant after a membership transition: on a
    /// cohort-bound pane the only legitimate `.session` subscribers are the
    /// cohort's current members, so revoke every subscriber the commit left
    /// outside the membership rather than chasing deltas. One rule covers a
    /// member a reconcile removed, a replaced cohort's member, a bound-in
    /// pane's non-member owner, and a `beginClose`'s leaving members. The
    /// commit already refuses them per-request; this tears down the streams
    /// they were admitted to earlier, which would otherwise keep receiving
    /// frames. No quiescence dance: the commit and a subscribe's final
    /// re-authorization run on this same actor, so an in-flight subscribe
    /// either landed in `subscribers` before the commit turn (this sweep
    /// catches it) or re-authorizes after it and is refused, the same
    /// reasoning as the foreign-owned stray arm of
    /// `revokeSessionSubscriptionsOnRecord`. `.guiPeer` is spared.
    private func sweepNonMemberSubscribers(cohortId: UUID) async {
        let memberIds = Set(cohortState.members(ofCohort: cohortId).map(\.sessionId))
        for record in panes.values.filter({ $0.cohortId == cohortId }) {
            let stale = Set(
                record.subscribers.values.compactMap { subscriber -> UUID? in
                    guard case let .session(sessionId, _) = subscriber.principal,
                        !memberIds.contains(sessionId) else { return nil }
                    return sessionId
                }
            )
            for sessionId in stale {
                await revokeSessionSubscribers(record: record, target: sessionId)
            }
        }
    }

    /// Hand a device consequence to the effect pump, inside the commit turn
    /// that decided it.
    private func emit(_ effect: CohortDeviceEffect) {
        deviceEffectSink?(effect)
    }

    /// Install the effect pump's enqueue (see `deviceEffectSink`).
    func setDeviceEffectSink(_ sink: @escaping @Sendable (CohortDeviceEffect) -> Void) {
        deviceEffectSink = sink
    }

    /// Point every record owned by `previous` and bound to `cohortId` at the
    /// inheriting member, and report the device targets that moved.
    ///
    /// Without this the record keeps naming the departed (or dropped)
    /// session, and the close sweep (`revokeSessionSubscriptionsOnRecord`)
    /// still sees it as owned by a closing session and raises `ownerRevoked`,
    /// which refuses every principal; the inheritor would receive a pane it
    /// is then forbidden to drive. Scoped to the one cohort, so a record the
    /// same session owns in some other cohort is left alone.
    @discardableResult
    private func rehome(from previous: UUID, to successor: CohortMember, cohortId: UUID) -> [PaneTarget] {
        var moved: [PaneTarget] = []
        for record in panes.values where record.sessionId == previous && record.cohortId == cohortId {
            record.sessionId = successor.sessionId
            record.acceptedIncarnation = successor.incarnation
            moved.append(record.target)
        }
        return moved
    }

    /// Tear a session out of its cohort, in one synchronous actor turn, before
    /// any asynchronous subscription cleanup runs.
    ///
    /// Clears the producer-local active incarnation here rather than leaving
    /// it to the subscription sweep that follows: a reconcile whose handler
    /// resolved this incarnation before the close could otherwise commit
    /// between the two and reinstall the departing member. With the entry
    /// cleared in the same turn as the membership removal, that reconcile
    /// either commits first (and this exact-member removal evicts what it
    /// installed) or fails its commit-time liveness check. The equality guard
    /// keeps a restored session's newer entry intact.
    func tearDownSession(_ sessionId: UUID, incarnation: UInt64) {
        if activeIncarnation[sessionId] == incarnation {
            activeIncarnation[sessionId] = nil
        }
        let member = CohortMember(sessionId: sessionId, incarnation: incarnation)
        let cohortId = cohortState.cohortId(forMember: member)
        switch cohortState.tearDown(member: member, now: DispatchTime.now().uptimeNanoseconds) {
        case .alreadyDecided, .terminal:
            // Already decided: an explicit close or a `beginClose` emitted the
            // consequences when it recorded the verdict. Terminal: a reap of a
            // last-or-only member dispositions nothing, because only an
            // explicit close carries a user's choice, and GUI recovery owns
            // the rest.
            return

        case let .promoted(successor):
            // A reaped member of a live tab: the survivors inherit its panes
            // and devices, or a sibling's pane would be `ownerRevoked` by the
            // subscription sweep that runs next.
            if let cohortId {
                rehome(from: sessionId, to: successor, cohortId: cohortId)
            }
            emit(
                .close(
                    CohortCloseEffect(
                        sessionId: sessionId,
                        incarnation: incarnation,
                        outcome: .promote(successor: successor.sessionId.uuidString)
                    )
                )
            )
        }
    }

    /// Decide and record the close verdict for a session whose explicit close
    /// is in flight, before the session is removed.
    ///
    /// Runs from the `session.close` handler's pre-removal seam. One
    /// synchronous turn decides the verdict, removes the membership, re-homes
    /// the records, and emits the device consequence; the teardown that
    /// follows removal finds the verdict recorded and owes nothing. A member
    /// outside any cohort takes the requested terminal arm.
    func recordCloseVerdict(sessionId: UUID, incarnation: UInt64, mode: PaneCloseMode) {
        let member = CohortMember(sessionId: sessionId, incarnation: incarnation)
        let cohortId = cohortState.cohortId(forMember: member)
        switch cohortState.recordCloseVerdict(
            member: member,
            mode: mode,
            now: DispatchTime.now().uptimeNanoseconds
        ) {
        case .alreadyRecorded:
            return

        case let .decided(outcome, successor):
            if let successor, let cohortId {
                rehome(from: sessionId, to: successor, cohortId: cohortId)
            }
            emit(
                .close(
                    CohortCloseEffect(
                        sessionId: sessionId,
                        incarnation: incarnation,
                        outcome: outcome
                    )
                )
            )
        }
    }

    /// Commit a close verdict for some of a cohort's members, returning the
    /// authoritative outcome the GUI records before it closes them.
    ///
    /// The commit is one synchronous turn (verdicts, membership removal,
    /// re-homing, and emission together), followed by the subscription sweep,
    /// which is part of the transition's completion: the commit withdraws the
    /// leaving members' authorization per-request, and the sweep tears down
    /// the streams they were admitted to earlier, before the reply.
    func beginCohortClose(
        cohortId: UUID,
        transitionId: UUID,
        leaving: [UUID],
        mode: PaneCloseMode,
        key: ProtectionOrderingKey
    ) async -> CohortCloseCommit {
        let commit = cohortState.beginClose(
            cohortId: cohortId,
            transitionId: transitionId,
            leaving: leaving,
            mode: mode,
            key: key,
            now: DispatchTime.now().uptimeNanoseconds
        )
        guard commit.applied, let outcome = commit.outcome, !commit.closed.isEmpty else {
            return commit
        }
        for member in commit.closed {
            if let successor = commit.successor {
                rehome(from: member.sessionId, to: successor, cohortId: cohortId)
            }
            emit(
                .close(
                    CohortCloseEffect(
                        sessionId: member.sessionId,
                        incarnation: member.incarnation,
                        outcome: outcome
                    )
                )
            )
        }
        await sweepNonMemberSubscribers(cohortId: cohortId)
        return commit
    }

    /// Whether a request's incarnation may reach `record`: an un-pinned pane
    /// (`acceptedIncarnation == nil`) or an un-pinned request (`nil`) admits;
    /// otherwise the two must be equal (the reincarnation ABA gate).
    private func incarnationAdmits(record: Record, requestIncarnation: UInt64?) -> Bool {
        guard let accepted = record.acceptedIncarnation, let requestIncarnation else { return true }
        return accepted == requestIncarnation
    }

    /// Resolve a pane's backend, gated first on **ownership** (via
    /// `authorize`) and then on a capability. Throws `notFound` if the
    /// paneId is unknown *or* the principal doesn't own it (indistinguishable
    /// by design), `paneNotActive` if the backend is gone (the device has
    /// shut down / detached and the backend was released), and
    /// `unsupportedOperation` if the backend exists but doesn't support
    /// `capability` (e.g. Crown on a physical device). Returns the record
    /// too, so a caller needing the pane's immutable fields (e.g.
    /// `accessibilityTree`'s `family`) doesn't do a second unauthorized
    /// `panes[paneId]` read. Every `pane.input.*` / `pane.ax.*` handler
    /// routes its backend lookup through here.
    private func requireBackend(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        supporting capability: KeyPath<DeviceBackendCapabilities, Bool>,
        operation: PaneOperation
    ) throws -> (record: Record, backend: any DeviceBackend) {
        let record = try authorize(paneId: paneId, as: principal, gatesInput: true)
        guard let backend = record.backend else {
            throw PaneError.paneNotActive(paneId: paneId)
        }
        guard backend.capabilities[keyPath: capability] else {
            throw PaneError.unsupportedOperation(paneId: paneId, operation: operation)
        }
        return (record, backend)
    }

    /// Resolve a pane's backend for an operation that will *send input*, and
    /// capture the backend's input generation in the same breath.
    ///
    /// Authorization and generation capture have to be synchronous with
    /// respect to each other. Otherwise an adoption can flip ownership and
    /// advance the backend generation in the gap, and the caller, authorized
    /// against the *previous* owner, then captures the *new* owner's
    /// generation and its input is accepted as current. (A stale generation
    /// is the harmless case: the backend's fence rejects it.) This helper has
    /// no suspension point, which is what makes that ordering a property of
    /// the code rather than a rule each call site has to remember.
    ///
    /// Carries the record alongside the backend so a caller needing the
    /// pane's own fields doesn't do a second, unauthorized `panes[paneId]`
    /// read.
    private func inputBackend(
        paneId: UUID,
        as principal: PaneAccessPrincipal,
        supporting capability: KeyPath<DeviceBackendCapabilities, Bool>,
        operation: PaneOperation
    ) throws -> AuthorizedInput {
        let (record, backend) = try requireBackend(
            paneId: paneId,
            as: principal,
            supporting: capability,
            operation: operation
        )
        return AuthorizedInput(
            record: record,
            backend: backend,
            generation: backend.currentInputGeneration()
        )
    }

    /// Loop the configured `mintShortID` strategy until a value
    /// outside the live pane short_id set is produced or
    /// `ShortID.maxMintAttempts` attempts elapse. Bounded retry: a
    /// buggy strategy or a pathologically saturated alphabet surfaces
    /// as `shortIDExhausted` rather than locking the actor.
    /// Whether `revision` may re-admit `record`.
    ///
    /// Only called for a revisioned request, since an unrevisioned re-attach
    /// doesn't re-admit at all. A record with no recorded revision accepts
    /// any, there being no series to compare against; otherwise the revision
    /// must strictly dominate, so a re-attach its own issuer has already
    /// superseded is refused rather than advancing the record behind that
    /// issuer's back.
    private func admits(_ revision: UInt64, over record: Record) -> Bool {
        guard let current = record.admissionRevision else { return true }
        return revision > current
    }

    /// Take the next attachment value. Synchronous and actor-isolated, so an
    /// admission stamps it in the same segment that commits the admission.
    private func allocateAttachment() -> UInt64 {
        defer { nextAttachment &+= 1 }
        return nextAttachment
    }

    private func allocateUniqueShortID() throws -> String {
        let existing = Set(panes.values.map(\.shortId))
        for _ in 0..<ShortID.maxMintAttempts {
            let candidate = mintShortID()
            if !existing.contains(candidate) { return candidate }
        }
        throw PaneError.shortIDExhausted
    }

    private func canonicalizeUDID(_ udid: String) throws -> String {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = UUID(uuidString: trimmed) else {
            throw PaneError.malformedUDID(udid: udid)
        }
        return parsed.uuidString.lowercased()
    }
}
