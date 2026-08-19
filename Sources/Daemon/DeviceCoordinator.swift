// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceCoordinator: the daemon's actor for sim lifecycle and
// provenance.
//
// CoreSimulator owns the actual simulator processes; we hold thin
// `SimDeviceHandle` references transiently and track *which sims we own*
// and, where there is one, the session attributed to each. The ownership map is the trust anchor for
// `device.list({scope: "owned"})` and for the menu bar's
// running-sim badge count, and is updated by:
//
//   - `boot(udid:owningSession:)` when the daemon initiates a boot on
//     behalf of a caller that's holding session creds.
//   - `recordOwnership`, reached by `shim.event` when a `simctl boot`
//     runs inside a tab's shell and the shim posts a provenance-tagged
//     event, and by `device.attach` when a caller claims an
//     already-booted sim.
//   - `restoreOwnership`, reached by `device.restoreOwnership` when a
//     validated GUI restores its claims to a daemon that restarted under
//     it. It changes bookkeeping without booting a sim or publishing
//     `device.booted`.
//
// Entries are removed by daemon shutdowns, by shim-reported shutdown
// events, and by CoreSimulator shutdown notifications.
//
// Handles never escape this actor: every public method either
// returns a `Sendable` snapshot (`CSBDeviceInfo`) or just an ack.
// The `SimDeviceHandle` is reacquired inside each call's actor-
// isolated body and dropped before the call returns. That matches
// the contract in `SimDeviceHandle.h` ("transient lookup result
// within a serializing context").

import CoreSimulatorBridge
import Foundation

public enum DeviceError: Error, Equatable, Sendable {
    case notFound(
        udid:
        String
        )
    case bootFailed(
        udid:
        String,
        message: String
        )
    case shutdownFailed(
        udid:
        String,
        message: String
        )
    case listFailed(
        message:
        String
        )
    /// `udid` parameter wasn't a well-formed string. UDID format on
    /// macOS is the standard 8-4-4-4-12 UUID. The bridge accepts it
    /// case-insensitively, but we still reject the empty string and
    /// other obvious junk before paying for a bridge round-trip.
    case malformedUDID(
        udid:
        String
        )
}

/// Plain `Sendable` snapshot of one owned, booted sim: exactly the
/// fields the status-item shutdown menu needs to list and act on it.
/// Decoupled from `CSBDeviceInfo` so the menu-model logic
/// (`statusMenuEntries`) stays pure and unit-testable without
/// constructing CoreSimulator types.
public struct OwnedSim: Sendable, Equatable {
    public let udid: String
    public let name: String
    public let runtimeIdentifier: String
    /// Session attributed to this sim per `DeviceCoordinator.ownership`.
    /// nil when the owned sim has no recorded attribution. The status-item
    /// menu groups a nil or unresolvable attribution under "Unlinked", and a
    /// live one under its session.
    public let sessionId: UUID?

    public init(
        udid: String,
        name: String,
        runtimeIdentifier: String,
        sessionId: UUID? = nil
    ) {
        self.udid = udid
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.sessionId = sessionId
    }
}

/// What `DeviceCoordinator.restoreOwnership` did: what to report, and which
/// entries it wrote, whose attribution may still need demoting after the
/// commit. Split so a caller revisits only what it added.
public struct OwnershipRestoreResult: Sendable, Equatable {
    /// Every normalized udid whose requested ownership and attribution now
    /// match, including ones that already matched before the call and ones
    /// claimed with no attribution. This is what the caller reports back: it
    /// answers "did the claim take", not "did you write it".
    public let attributed: Set<String>
    /// Only the entries this call wrote, keyed by normalized udid, with the
    /// attribution it wrote (nil for an unattributed one). It identifies
    /// exactly which newly written attributions may still need demoting; the
    /// ownership itself stands either way.
    public let written: [String: UUID?]

    public init(attributed: Set<String>, written: [String: UUID?]) {
        self.attributed = attributed
        self.written = written
    }
}

/// One CoreSimulator notification paired with the instant it arrived.
///
/// The consumer handles events serially and a handler can run long, so
/// "now" inside a handler is not when the notification landed. The publish
/// debounce compares source timestamps, and for the notification path that
/// timestamp is callback arrival rather than handler processing time.
/// Otherwise a slow handler stretches the apparent gap and a duplicate
/// queued right behind the first reads as a fresh transition.
struct NotifierArrival: Sendable {
    let event: CSBNotifierEvent
    let arrivedAt: Date
}

public actor DeviceCoordinator {
    /// UDID (lowercased) → the session attributed to it, or nil for one
    /// explicitly claimed without an attribution. Cleared when the sim shuts
    /// down.
    ///
    /// A present key means deviceterm owns the sim; the value is only its
    /// attribution. Those are separate facts: a tab closed with Detach ends
    /// its session while the sim keeps running and stays ours, which the
    /// status item lists under "Unlinked". A stored UUID naming a session
    /// that has since closed resolves the same way there.
    ///
    /// Reach it through `owns(_:)` and `owner(of:)` rather than subscripting,
    /// so the two levels never get confused: a bare subscript yields a double
    /// optional, the outer being ownership and the inner attribution.
    private var ownership: [String: UUID?] = [:]
    /// Optional event broker. Publishes `device.booted` + `device.shutdown`
    /// to every session's `deviceterm events` subscribers (device events
    /// are `.everyone`).
    private let eventBroker: EventBroker?

    /// CoreSimulator notification subscription. Held for the
    /// daemon's lifetime so set-level notifications continue to
    /// arrive. Nil until `subscribeToCoreSimulator(paneShutdownConverger:)`
    /// is called and after `unsubscribeFromCoreSimulator()` runs.
    ///
    /// `CSBDeviceNotifier` isn't `Sendable` (instance methods reach
    /// private framework state); keeping it inside the actor means
    /// it never crosses an isolation boundary.
    private var notifier: CSBDeviceNotifier?

    /// Drives every pane attached to a shut-down UDID into `.shutdown`.
    /// Supplied by `subscribeToCoreSimulator(paneShutdownConverger:)`
    /// rather than at construction, since a coordinator that never
    /// subscribes never observes an external shutdown. Module-internal
    /// rather than private so the notification tests can drive
    /// convergence without registering a real CoreSimulator subscription.
    var paneShutdownConverger: (@Sendable (String) async -> Void)?

    /// Continuation for the `AsyncStream<NotifierArrival>` that
    /// the bridge handler yields into. Held so `unsubscribe…` can
    /// `finish()` the stream and the consumer task can exit.
    private var notifierContinuation: AsyncStream<NotifierArrival>.Continuation?

    /// Long-lived consumer task driving `for await arrival in stream`.
    /// Naturally actor-isolated, serial, and a single allocation
    /// for the daemon's lifetime, versus a `Task { await … }` per
    /// event, which would scatter ordering across reentrancy.
    private var notifierConsumer: Task<Void, Never>?

    /// Last authoritative (`boot` RPC or shim `recordOwnership`)
    /// `deviceBooted` publish per UDID. Used by the notification
    /// path to debounce a follow-up `noteExternalBoot` that lands
    /// after the authoritative one fired for the same boot. NOT
    /// consulted by authoritative publishers themselves. Back-to-
    /// back shim records (e.g. session B reclaiming session A's
    /// UDID) are distinct real events and must each fire.
    private var recentAuthoritativeBoots: [String: Date] = [:]
    /// Last notification-path `deviceBooted` publish per UDID.
    /// Used by authoritative publishers to debounce a shim record
    /// that lands after the notification fired for the same boot,
    /// and by the notification path to debounce itself against
    /// duplicate notifications.
    private var recentNotificationBoots: [String: Date] = [:]
    /// Shutdown mirrors: same shape, same semantics.
    private var recentAuthoritativeShutdowns: [String: Date] = [:]
    private var recentNotificationShutdowns: [String: Date] = [:]
    /// How long after a publish to suppress duplicates from the
    /// other source. 500 ms is comfortably wider than the observed
    /// shim-vs-notification skew and well below the shortest sim
    /// boot→render time, so it can't accidentally suppress a real
    /// successor event. Injectable so tests covering "work slower than
    /// the window" can shrink it instead of sleeping half a second each.
    private let debounceWindow: TimeInterval
    /// CoreSimulator enumeration behind `listAll()` and everything built on it.
    /// Production reads the bridge directly; tests inject a reader that fails
    /// if called, pinning that empty ownership never enumerates at all.
    private let readDevices: @Sendable () throws -> [CSBDeviceInfo]
    /// The udids CoreSimulator currently reports as `Booted`, lowercased, or
    /// nil when the bridge couldn't enumerate at all. The one place the two
    /// questions that need live boot state but not the rest of a device
    /// record read it from.
    ///
    /// Injected because those questions are pure decisions over the answer,
    /// and pinning them otherwise takes a booted simulator: the live track
    /// covers the bridge, and a hermetic test covers what the daemon does
    /// with what the bridge said. The `listOwned…` readers keep their own
    /// enumeration; they need each device's name and runtime too.
    private let readBootedUDIDs: @Sendable () -> Set<String>?

    /// Diagnostic accessor: raw size of the ownership map, i.e. how
    /// many sims deviceterm considers itself the owner of. Tests only;
    /// it does not reflect live boot state, so nothing user-facing
    /// derives from it. The status item counts `listOwnedBooted()`.
    public var ownedCount: Int { ownership.count }

    /// Whether the CoreSimulator notification subscription is
    /// currently installed. Diagnostic for tests; the daemon never
    /// branches on this in production.
    public var isSubscribedToCoreSimulator: Bool { notifier != nil }

    public init(
        eventBroker: EventBroker? = nil,
        debounceWindow: TimeInterval = 0.5,
        readBootedUDIDs: @escaping @Sendable () -> Set<String>? = bootedUDIDsFromCoreSimulator
    ) {
        self.eventBroker = eventBroker
        self.debounceWindow = debounceWindow
        self.readDevices = { try SimDeviceHandle.allDevices() }
        self.readBootedUDIDs = readBootedUDIDs
    }

    /// Module-internal test seam for observing `listAll()` enumeration
    /// without adding a public initializer parameter.
    init(
        eventBroker: EventBroker? = nil,
        debounceWindow: TimeInterval = 0.5,
        readBootedUDIDs: @escaping @Sendable () -> Set<String>? = bootedUDIDsFromCoreSimulator,
        readDevices: @escaping @Sendable () throws -> [CSBDeviceInfo]
    ) {
        self.eventBroker = eventBroker
        self.debounceWindow = debounceWindow
        self.readDevices = readDevices
        self.readBootedUDIDs = readBootedUDIDs
    }

    /// Production's `readBootedUDIDs`: one CoreSimulator enumeration reduced
    /// to lowercased udids. Nil on a bridge failure, which every caller reads
    /// as "can't confirm" rather than "nothing is booted".
    public static func bootedUDIDsFromCoreSimulator() -> Set<String>? {
        guard let devices = try? SimDeviceHandle.allDevices() else { return nil }
        return Set(devices.filter { $0.state == .booted }.map { $0.udid.lowercased() })
    }

    // MARK: - Listing

    /// Every device CoreSimulator knows about. Throws if the bridge
    /// can't enumerate, e.g. CoreSimulator isn't loadable on the
    /// host. Used to back `device.list({scope: "all"})`.
    public func listAll() throws -> [CSBDeviceInfo] {
        do {
            return try readDevices()
        } catch {
            throw DeviceError.listFailed(message: String(describing: error))
        }
    }

    /// Subset of `listAll()` filtered to the sims deviceterm currently
    /// considers itself the owner of. The filter is intersection-
    /// based: a UDID in the ownership map that's no longer in
    /// CoreSimulator's device set drops out, so callers don't see
    /// stale records.
    public func listOwned() throws -> [CSBDeviceInfo] {
        let all = try listAll()
        return all.filter { owns($0.udid.lowercased()) }
    }

    /// Number of owned sims currently in the `Booted` state.
    /// Distinct from `ownedCount` (raw map size): a sim shut down
    /// externally (Simulator.app, `simctl shutdown`, crash) leaves
    /// a stale ownership record until something else clears it,
    /// and using the map size for status-item visibility or idle-
    /// exit liveness would lie. Falls back to 0 on bridge failure:
    /// a degraded CoreSimulator means we can't confirm liveness, so
    /// the daemon's "I'm alive holding sims" signal hides rather
    /// than asserting something we can't verify.
    /// When the ownership map is empty, returns 0 without consulting
    /// CoreSimulator: no live device can intersect an empty owned set.
    public func ownedBootedCount() -> Int {
        guard !ownership.isEmpty else { return 0 }
        let devices: [CSBDeviceInfo]
        do {
            devices = try listOwned()
        } catch {
            return 0
        }
        return devices.filter { $0.state == .booted }.count
    }

    /// Owned sims currently in the `Booted` state, as plain `Sendable`
    /// snapshots for the status-item menu. The status item takes one of
    /// these per poll tick and derives *both* its badge visibility and
    /// count and its shutdown menu (`statusMenuEntries`) from the same
    /// snapshot, so the two can never disagree across separate
    /// CoreSimulator reads. Falls back to `[]` on bridge failure, the
    /// same degraded-but-honest posture as `ownedBootedCount()`.
    /// When the ownership map is empty, returns `[]` without consulting
    /// CoreSimulator, since no live device can intersect an empty owned set.
    public func listOwnedBooted() -> [OwnedSim] {
        guard !ownership.isEmpty else { return [] }
        let devices: [CSBDeviceInfo]
        do {
            devices = try listOwned()
        } catch {
            return []
        }
        return devices
            .filter { $0.state == .booted }
            .map { OwnedSim(
                udid: $0.udid,
                name: $0.name,
                runtimeIdentifier: $0.runtimeIdentifier,
                sessionId: owner(of: $0.udid.lowercased())
            )
            }
    }

    /// Session that owns `udid`, if any. Used to populate the
    /// `ownedBySession` field on the wire when a caller asks for the
    /// "all" scope.
    public func ownerSession(forUDID udid: String) -> UUID? {
        owner(of: udid.lowercased())
    }

    /// Whether `udid` is currently `Booted` per a live CoreSimulator
    /// query, independent of ownership. The shutdown-convergence path
    /// uses this to tell "shutdown failed because the sim is already
    /// gone" (mark its panes shut down) from "shutdown genuinely failed
    /// while the sim is still up" (leave the pane live). Returns `false`
    /// if the bridge can't enumerate: a degraded CoreSimulator can't
    /// confirm liveness, so we don't assert the sim is still running.
    public func isBooted(udid: String) -> Bool {
        readBootedUDIDs()?.contains(udid.lowercased()) ?? false
    }

    // MARK: - Lifecycle

    /// Boot a device by UDID. Returns when CoreSimulator has accepted
    /// the boot *intent* (not when SpringBoard has rendered, which is
    /// `SimDisplayHandle`'s job, and is observed via the pane's
    /// `surface.changed` events once that chunk lands).
    ///
    /// `owningSession`, when non-nil, claims provenance: the booted
    /// sim is recorded as owned by that session. The session-cap
    /// gate happens upstream in `DeviceMethods`, and `DeviceCoordinator`
    /// trusts whatever UUID it's handed.
    public func boot(udid: String, owningSession: UUID? = nil) async throws {
        let normalized = try requireValidUDID(udid)
        let handle: SimDeviceHandle
        do {
            handle = try SimDeviceHandle.handle(forUDID: normalized)
        } catch {
            throw DeviceError.notFound(udid: normalized)
        }
        do {
            try handle.boot()
        } catch {
            throw DeviceError.bootFailed(
                udid: normalized,
                message: String(describing: error)
            )
        }
        if let owningSession {
            ownership[normalized] = owningSession
        }
        // Publish device.booted to the event stream (device events reach
        // every session). Agents watching `deviceterm events` pick up here. Goes
        // through the debounce helper so the CoreSimulator
        // notification path (which sees the same transition) can't
        // double-publish.
        await publishBoot(udid: normalized)
    }

    /// Shut down a device by UDID. The CoreSimulator call is
    /// synchronous; on success we drop any ownership record for the
    /// sim, since a shut-down sim isn't owned by anyone (its UDID can be
    /// freely re-booted by a different session later).
    public func shutdown(udid: String) async throws {
        let normalized = try requireValidUDID(udid)
        let handle: SimDeviceHandle
        do {
            handle = try SimDeviceHandle.handle(forUDID: normalized)
        } catch {
            throw DeviceError.notFound(udid: normalized)
        }
        do {
            try handle.shutdown()
        } catch {
            throw DeviceError.shutdownFailed(
                udid: normalized,
                message: String(describing: error)
            )
        }
        ownership.removeValue(forKey: normalized)
        // Publish device.shutdown. Symmetric with boot: debounced
        // against a same-UDID notification arrival.
        await publishShutdown(udid: normalized)
    }

    // MARK: - Ownership manipulation (for shim events + tests)

    /// Record that a session owns this UDID. Called by `shim.event`
    /// handling when a `simctl boot` runs inside a tab's shell.
    /// Idempotent: repeat calls for the same UDID overwrite the
    /// owning session (last writer wins, matches the GUI's
    /// "Already attached in tab X. Move? [y/n]" semantics).
    ///
    /// Publishes `device.booted` here too. This is the primary
    /// in-tab workflow path (per the "Getting a sim into your tab"
    /// agent guide): `xcrun simctl boot` runs inside the tab, the
    /// shim intercepts, the daemon learns about it via
    /// `recordOwnership` rather than the daemon-side `boot(...)`
    /// RPC. Without publishing here, `deviceterm events` would miss
    /// every in-tab boot, the primary use case.
    public func recordOwnership(udid: String, sessionId: UUID) async throws {
        let normalized = try requireValidUDID(udid)
        ownership[normalized] = sessionId
        // Shim sent us one boot event; publish regardless of prior
        // ownership state. A re-record (session B claiming session
        // A's previously-owned UDID) corresponds to a fresh shim-
        // intercepted boot and is a real `device.booted` event. The
        // debounce window suppresses a follow-up CoreSimulator
        // notification for the same UDID landing milliseconds later.
        await publishBoot(udid: normalized)
    }

    /// Restore ownership claims for already-booted sims, for a daemon that
    /// came back holding nothing. Returns the normalized udids whose requested
    /// ownership and attribution now match, a subset of what was asked for.
    ///
    /// Nothing is booted and no `device.booted` event is published: no sim
    /// changed state, and a subscriber told otherwise would see a boot that
    /// never happened. This is bookkeeping catching up with reality, not a
    /// transition.
    ///
    /// Two refusals, both silent, because neither is the caller's fault:
    ///
    ///   - A udid this daemon ALREADY owns keeps its existing attribution,
    ///     including an unattributed one. The live map is newer than any mirror
    ///     a caller can hold, so a re-assertion fills gaps rather than arguing;
    ///     asking for the attribution it already has still counts as restored,
    ///     so a retry is idempotent.
    ///   - A udid CoreSimulator does not currently report as Booted is not
    ///     claimed at all. A sim that shut down while nobody was watching is
    ///     gone, and claiming it would put a device deviceterm no longer owns
    ///     back into the shut-down prompts.
    ///
    /// The booted set is read ONCE for the whole batch rather than per udid,
    /// and gates what is REPORTED as well as what is written. An attribution
    /// this daemon already holds can be stale (nothing disowns a sim that shut
    /// down until the notifier says so), so reporting it without checking
    /// would answer "restored" for a sim that is gone.
    ///
    /// A bridge that can't answer reports nothing, matching the rest of this
    /// actor's "a degraded CoreSimulator asserts nothing" posture: it can't
    /// confirm any sim is up, including the ones already attributed.
    public func restoreOwnership(_ claims: [String: UUID?]) -> OwnershipRestoreResult {
        guard !claims.isEmpty, let booted = readBootedUDIDs() else {
            return OwnershipRestoreResult(attributed: [], written: [:])
        }
        var attributed: Set<String> = []
        var written: [String: UUID?] = [:]
        for (udid, sessionId) in claims {
            let normalized = udid.lowercased()
            guard booted.contains(normalized) else { continue }
            if owns(normalized) {
                // Ownership already recorded. Report it only when the
                // attribution agrees, including nil against nil, so a retry is
                // idempotent while a disagreement loses to what is already here.
                if owner(of: normalized) == sessionId { attributed.insert(normalized) }
                continue
            }
            ownership[normalized] = sessionId
            attributed.insert(normalized)
            written[normalized] = sessionId
        }
        return OwnershipRestoreResult(attributed: attributed, written: written)
    }

    /// Drop the attribution from ownership entries whose session has since
    /// gone, keeping the ownership itself.
    ///
    /// Demoting rather than removing, because a session ending is not a sim
    /// ending: that is the state closing a tab with Detach leaves behind, and
    /// the status item lists it under "Unlinked". Removing the entry would
    /// instead leave a running sim nothing claims, so nothing offers to shut
    /// it down.
    ///
    /// The one caller is `device.restoreOwnership`, for a claim whose named
    /// session it could not confirm live.
    ///
    /// Compare-and-set: an entry moves only while the recorded owner is still
    /// the session named, so an attribution something else has made for the
    /// same sim since survives. Publishes nothing; no sim changed state.
    public func demoteOwnership(_ entries: [String: UUID]) {
        for (udid, sessionId) in entries {
            let normalized = udid.lowercased()
            guard owns(normalized), owner(of: normalized) == sessionId else { continue }
            ownership[normalized] = UUID?.none
        }
    }

    /// Drop the ownership record for `udid` without affecting the
    /// sim itself. Reached by the shim's shutdown event.
    ///
    /// Publishes `device.shutdown` here for the shim-shutdown path.
    /// Symmetric with `recordOwnership` and covers the in-tab
    /// `xcrun simctl shutdown <UDID>` workflow.
    public func releaseOwnership(udid: String) async {
        let normalized = udid.lowercased()
        ownership.removeValue(forKey: normalized)
        // The shim told us this UDID has shut down. Publish even if
        // our ownership map didn't have a record (the shim's view
        // of reality is the truth here). Debounced against a
        // CoreSimulator notification arriving for the same UDID.
        await publishShutdown(udid: normalized)
    }

    /// Remove every ownership record attributed to a session in `sessionIds`,
    /// leaving unattributed entries alone.
    public func releaseOwnership(for sessionIds: Set<UUID>) {
        ownership = ownership.filter { entry in
            guard let attributed = entry.value else { return true }
            return !sessionIds.contains(attributed)
        }
    }

    // MARK: - CoreSimulator notification subscription
    //
    // Set-level subscription via `CSBDeviceNotifier`. Catches every
    // sim state transition regardless of who initiated it: shim-
    // intercepted `simctl boot`, xcodebuild's destination boot,
    // absolute-path `/usr/bin/xcrun simctl boot`, FFI callers
    // bypassing xcrun entirely, Simulator.app's File → Open Device,
    // and sims booted before the daemon started. Without this,
    // deviceterm's view of "what's running" depends on whether the
    // shim happened to be on the boot caller's PATH, which the
    // watchOS game-dev `./sim run` workflow showed is unreliable
    // for callers that bypass deviceterm's bin shim entirely.

    /// Install the notification subscription. Idempotent: calling
    /// twice without unsubscribing in between leaves the existing
    /// subscription in place and returns. Throws only on bridge-
    /// load failure (CoreSimulator unavailable, registration
    /// returned 0); callers that hit those should log + degrade
    /// gracefully (no notifications, but the shim path still works
    /// and `device.list` polling still surfaces booted sims).
    ///
    /// Shape: the ObjC handler yields to an `AsyncStream`, and a
    /// long-lived consumer task loops `for await arrival in stream`,
    /// calling the actor-isolated handler. The `DispatchQueue`
    /// passed to the bridge is an unavoidable CoreSimulator
    /// requirement (the private API takes a `dispatch_queue_t`);
    /// CoreSimulator retains it for the registration's lifetime so
    /// the local scope here is sound.
    ///
    /// `paneShutdownConverger` is a parameter rather than a settable
    /// property so the notifier cannot be installed without pane-shutdown
    /// handling. An observed shutdown that doesn't reach the pane registry
    /// leaves the pane frozen on its last frame with no Reboot/Close
    /// affordance.
    public func subscribeToCoreSimulator(
        paneShutdownConverger: @escaping @Sendable (String) async -> Void
    ) throws {
        if notifier != nil { return }
        let (stream, continuation) = AsyncStream<NotifierArrival>.makeStream()
        let queue = DispatchQueue(
            label: "com.deviceterm.daemon.devicenotifier",
            qos: .userInitiated
        )
        let notifier = try CSBDeviceNotifier.defaultNotifier(queue: queue) { event in
            // Stamped on CoreSimulator's callback queue, the only place
            // that knows when the notification arrived. The consumer below
            // handles events one at a time and a handler can run long, so a
            // queued event's own `Date()` can sit far from the transition it
            // describes.
            continuation.yield(NotifierArrival(event: event, arrivedAt: Date()))
        }
        // Installed only once registration succeeded, so a bridge-load
        // failure leaves no converger behind a notifier that never exists.
        self.paneShutdownConverger = paneShutdownConverger
        self.notifier = notifier
        self.notifierContinuation = continuation
        self.notifierConsumer = Task { [weak self] in
            for await arrival in stream {
                await self?.handleNotifierEvent(arrival)
            }
        }
    }

    /// Drop the subscription. Idempotent. Called on daemon
    /// shutdown so CoreSimulator doesn't retain a callback into
    /// the (about-to-disappear) actor. Order: cancel the bridge
    /// registration first (CoreSimulator stops dispatching to the
    /// block), then finish the stream so the consumer task exits
    /// cleanly. The consumer task isn't `cancel()`-ed because the
    /// `for await` loop ends naturally when the stream finishes, since
    /// cancelling would race the bridge handler's last yield.
    public func unsubscribeFromCoreSimulator() {
        notifier?.cancel()
        notifier = nil
        notifierContinuation?.finish()
        notifierContinuation = nil
        notifierConsumer = nil
        paneShutdownConverger = nil
    }

    /// Dispatch a notification arriving from CoreSimulator into
    /// the right state mutation. The notifier wrapper only
    /// surfaces `.stateChanged` events with a populated UDID;
    /// `.other` and empty-UDID events drop here without effect.
    func handleNotifierEvent(_ arrival: NotifierArrival) async {
        let event = arrival.event
        guard event.kind == .stateChanged, !event.udid.isEmpty else { return }
        switch event.newState {
        case .booted:
            await noteExternalBoot(udid: event.udid, arrivedAt: arrival.arrivedAt)

        case .shutdown:
            await noteExternalShutdown(udid: event.udid, arrivedAt: arrival.arrivedAt)

        case .unknown, .creating, .booting, .shuttingDown:
            // Intermediate states aren't actionable: the daemon's
            // wire model only emits `.booted` / `.shutdown`. A
            // sim that stalls in `.booting` is observed as
            // "still booting" via the discovery poll; no need
            // to invent a new event type for it.
            break

        @unknown default:
            break
        }
    }

    /// External-boot path: the notification said a UDID entered
    /// `.booted` but no recent `recordOwnership` or `boot()` call
    /// claimed it. Publish the event so subscribers see the boot;
    /// don't record ownership (the sim has no attributed session,
    /// matching the linkage-model's "external sims stay unattached"
    /// property, though the user can claim it via `deviceterm pane attach`).
    /// `arrivedAt` defaults to now for direct callers; the notifier passes
    /// the delivery timestamp. A boot queued behind a slow shutdown handler
    /// would otherwise be timed from when it got a turn.
    func noteExternalBoot(udid: String, arrivedAt: Date = Date()) async {
        let normalized = udid.lowercased()
        await publishBootDebounced(udid: normalized, arrivedAt: arrivedAt)
    }

    /// External-shutdown path: a UDID transitioned to `.shutdown`.
    /// Drop any ownership record (the sim is gone regardless of
    /// who shut it down) and publish, debounced against a
    /// concurrent shim shutdown event for the same UDID.
    ///
    /// Also converges any pane attached to that UDID. This is the
    /// fourth shutdown surface, and the only one that catches a sim
    /// killed by something outside deviceterm entirely: quitting
    /// Simulator.app (which shuts down the devices it attached to), a
    /// `simctl shutdown` from an unshimmed shell, or a crash. Without
    /// it the sim's frames simply stop arriving and the pane sits on
    /// its last frame with live-looking controls that no longer do
    /// anything. Convergence is idempotent, so a shutdown deviceterm
    /// itself initiated (already converged by its own path) costs a
    /// no-op here.
    /// `arrivedAt` carries the notification's true arrival instant; see
    /// `NotifierArrival`. It defaults to now for direct callers.
    func noteExternalShutdown(udid: String, arrivedAt: Date = Date()) async {
        let normalized = udid.lowercased()
        ownership.removeValue(forKey: normalized)
        // Settle the debounce against `arrivedAt` before converging: both
        // the window comparison and the recorded stamp. Backend teardown is
        // unbounded and holds the serial consumer, so a queued duplicate
        // doesn't start until it finishes; timing either half from
        // processing would let that duplicate escape the window.
        let shouldPublish = admitNotificationShutdown(udid: normalized, arrivedAt: arrivedAt)
        // Publish first, matching the commanded path in
        // `DeviceMethods.shutdownConverged`. Convergence suspends this actor
        // and exposes the shutdown elsewhere: retiring a pane yields
        // `.stateChanged(.shutdown)` to its subscribers and puts a Reboot
        // affordance in front of the user. Anything that reacts by booting
        // publishes while this call is still suspended, so a boot event
        // would precede the shutdown that caused it.
        if shouldPublish {
            await eventBroker?.publish(.deviceShutdown(udid: normalized), to: .everyone)
        }
        await paneShutdownConverger?(normalized)
    }

    // MARK: - Publish debounce
    //
    // Two sources converge here: the AUTHORITATIVE path (the `boot`
    // / `shutdown` RPCs and the shim's `recordOwnership` /
    // `releaseOwnership`) and the NOTIFICATION path (CoreSimulator's
    // device-set notifier). Each source is debounced ONLY against
    // the OTHER source within `debounceWindow`. Two consecutive
    // authoritative publishes (e.g. session B reclaiming a UDID
    // session A had owned) are distinct real events and both fire;
    // a notification that arrives ~tens of ms after the shim for
    // the same physical boot is suppressed.
    //
    // The notification path also debounces against itself, so a
    // duplicate notification (rare) doesn't double-emit.

    /// Authoritative `deviceBooted` publish, used by `boot()` and
    /// `recordOwnership()`. Skipped only when the notification path
    /// fired for the same UDID within the debounce window.
    private func publishBoot(udid: String) async {
        let now = Date()
        recentAuthoritativeBoots[udid] = now
        if let last = recentNotificationBoots[udid],
            now.timeIntervalSince(last) < debounceWindow {
            return
        }
        // `.everyone`: a udid leaks nothing `device.list` (daemon-wide)
        // doesn't already. If `device.list` is ever scoped, these move too.
        await eventBroker?.publish(.deviceBooted(udid: udid), to: .everyone)
    }

    /// Notification-path `deviceBooted` publish, used by
    /// `noteExternalBoot`. Skipped when either an authoritative
    /// publish or another notification fired for the same UDID
    /// within the window.
    private func publishBootDebounced(udid: String, arrivedAt now: Date = Date()) async {
        let lastAuth = recentAuthoritativeBoots[udid]
        let lastNotif = recentNotificationBoots[udid]
        recentNotificationBoots[udid] = now
        if let lastAuth, now.timeIntervalSince(lastAuth) < debounceWindow {
            return
        }
        if let lastNotif, now.timeIntervalSince(lastNotif) < debounceWindow {
            return
        }
        // `.everyone`: a udid leaks nothing `device.list` (daemon-wide)
        // doesn't already. If `device.list` is ever scoped, these move too.
        await eventBroker?.publish(.deviceBooted(udid: udid), to: .everyone)
    }

    /// Authoritative `deviceShutdown` publish, used by `shutdown()`
    /// and `releaseOwnership()`. Mirror of `publishBoot`.
    private func publishShutdown(udid: String) async {
        let now = Date()
        recentAuthoritativeShutdowns[udid] = now
        if let last = recentNotificationShutdowns[udid],
            now.timeIntervalSince(last) < debounceWindow {
            return
        }
        await eventBroker?.publish(.deviceShutdown(udid: udid), to: .everyone)
    }

    /// Notification-path `deviceShutdown` admission, used by
    /// `noteExternalShutdown`. Records this arrival and answers whether it
    /// is the one that should publish.
    ///
    /// Split into a decision instead of mirroring `publishBootDebounced`'s
    /// decide-and-publish shape because pane convergence follows this call
    /// and the notifier's consumer handles events one at a time. The next
    /// notification waits out that convergence before it can be admitted,
    /// so both halves of the debounce, the window comparison and recording
    /// this arrival, settle synchronously against `arrivedAt` (see
    /// `NotifierArrival`) rather than whenever a handler reaches them. The
    /// boot path has no comparable work and needs no split.
    private func admitNotificationShutdown(udid: String, arrivedAt now: Date) -> Bool {
        let lastAuth = recentAuthoritativeShutdowns[udid]
        let lastNotif = recentNotificationShutdowns[udid]
        recentNotificationShutdowns[udid] = now
        if let lastAuth, now.timeIntervalSince(lastAuth) < debounceWindow {
            return false
        }
        if let lastNotif, now.timeIntervalSince(lastNotif) < debounceWindow {
            return false
        }
        return true
    }

    // MARK: - Internal helpers

    /// Whether deviceterm owns this (normalized) udid at all, attributed or
    /// not.
    private func owns(_ normalized: String) -> Bool {
        ownership.index(forKey: normalized) != nil
    }

    /// The session attributed to this (normalized) udid. Nil both for a sim
    /// deviceterm owns unattributed and for one it doesn't own; callers that
    /// need to tell those apart ask `owns(_:)` too.
    private func owner(of normalized: String) -> UUID? {
        // The outer level answers "owned"; the inner one is the attribution,
        // and returning it unchanged is the point.
        guard let attribution = ownership[normalized] else { return nil }
        return attribution
    }

    /// Canonicalize a UDID for use as an ownership-map key.
    ///
    /// CoreSimulator UDIDs are standard UUIDs (8-4-4-4-12 hex,
    /// case-insensitive). Rejecting anything that doesn't parse as a
    /// UUID keeps junk strings out of the ownership map: without it,
    /// a malformed shim event or buggy caller can inflate
    /// `ownedCount` for a device that can never be in CoreSimulator's
    /// enumeration, which would lie to the status-item count and to
    /// every `device.list({scope: "owned"})` consumer.
    private func requireValidUDID(_ udid: String) throws -> String {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = UUID(uuidString: trimmed) else {
            throw DeviceError.malformedUDID(udid: udid)
        }
        return parsed.uuidString.lowercased()
    }
}
