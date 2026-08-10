// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceCoordinator: the daemon's actor for sim lifecycle and
// provenance.
//
// CoreSimulator owns the actual simulator processes; we hold thin
// `SimDeviceHandle` references transiently and track *which session
// booted each sim we own*. The ownership map is the trust anchor for
// `device.list({scope: "owned"})` and for the menu bar's
// running-sim badge count, and is updated by:
//
//   - `boot(udid:owningSession:)` when the daemon initiates a boot on
//     behalf of a caller that's holding session creds.
//   - `recordOwnership`, reached by `shim.event` when a `simctl boot`
//     runs inside a tab's shell and the shim posts a provenance-tagged
//     event, and by `device.attach` when a caller claims an
//     already-booted sim.
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
    /// Session that owns this sim per `DeviceCoordinator.ownership`.
    /// nil when the sim is owned by the daemon but its session record
    /// has been dropped (cold-start orphan); the status-item menu
    /// uses this to group sims under their owning session.
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

public actor DeviceCoordinator {
    /// UDID (lowercased) → sessionId of the session that booted it.
    /// Populated by `boot(udid:owningSession:)` and (in a future
    /// chunk) by shim-event handling. Cleared when the sim shuts
    /// down or its owning session closes.
    private var ownership: [String: UUID] = [:]
    /// Optional event broker. Publishes `device.booted` + `device.shutdown`
    /// to every session's `deviceterm events` subscribers (device events
    /// are `.everyone`).
    private let eventBroker: EventBroker?

    /// CoreSimulator notification subscription. Held for the
    /// daemon's lifetime so set-level notifications continue to
    /// arrive. Nil until `subscribeToCoreSimulator()` is called and
    /// after `unsubscribeFromCoreSimulator()` runs.
    ///
    /// `CSBDeviceNotifier` isn't `Sendable` (instance methods reach
    /// private framework state); keeping it inside the actor means
    /// it never crosses an isolation boundary.
    private var notifier: CSBDeviceNotifier?

    /// Continuation for the `AsyncStream<CSBNotifierEvent>` that
    /// the bridge handler yields into. Held so `unsubscribe…` can
    /// `finish()` the stream and the consumer task can exit.
    private var notifierContinuation: AsyncStream<CSBNotifierEvent>.Continuation?

    /// Long-lived consumer task driving `for await event in stream`.
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
    /// successor event.
    private let debounceWindow: TimeInterval = 0.5

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
        eventBroker: EventBroker? = nil
    ) {
        self.eventBroker = eventBroker
    }

    // MARK: - Listing

    /// Every device CoreSimulator knows about. Throws if the bridge
    /// can't enumerate, e.g. CoreSimulator isn't loadable on the
    /// host. Used to back `device.list({scope: "all"})`.
    public func listAll() throws -> [CSBDeviceInfo] {
        do {
            return try SimDeviceHandle.allDevices()
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
        return all.filter { ownership[$0.udid.lowercased()] != nil }
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
    public func ownedBootedCount() -> Int {
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
    public func listOwnedBooted() -> [OwnedSim] {
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
                sessionId: ownership[$0.udid.lowercased()]
            )
            }
    }

    /// Session that owns `udid`, if any. Used to populate the
    /// `ownedBySession` field on the wire when a caller asks for the
    /// "all" scope.
    public func ownerSession(forUDID udid: String) -> UUID? {
        ownership[udid.lowercased()]
    }

    /// Whether `udid` is currently `Booted` per a live CoreSimulator
    /// query, independent of ownership. The shutdown-convergence path
    /// uses this to tell "shutdown failed because the sim is already
    /// gone" (mark its panes shut down) from "shutdown genuinely failed
    /// while the sim is still up" (leave the pane live). Returns `false`
    /// if the bridge can't enumerate: a degraded CoreSimulator can't
    /// confirm liveness, so we don't assert the sim is still running.
    public func isBooted(udid: String) -> Bool {
        guard let devices = try? listAll() else { return false }
        let needle = udid.lowercased()
        return devices.contains {
            $0.udid.lowercased() == needle && $0.state == .booted
        }
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

    /// Drop the ownership record for `udid` without affecting the
    /// sim itself. Called when a session closes (its sims are
    /// disowned but stay running per the "Detach" semantics) and
    /// when shim shutdown events come in.
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

    /// Drop every ownership record for sessions in `sessionIds`.
    /// Used by future session-close handling: closing a session
    /// disowns its sims (they keep running; just no longer
    /// attributed to a live session).
    public func releaseOwnership(for sessionIds: Set<UUID>) {
        ownership = ownership.filter { !sessionIds.contains($0.value) }
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
    /// long-lived consumer task loops `for await event in stream`,
    /// calling the actor-isolated handler. The `DispatchQueue`
    /// passed to the bridge is an unavoidable CoreSimulator
    /// requirement (the private API takes a `dispatch_queue_t`);
    /// CoreSimulator retains it for the registration's lifetime so
    /// the local scope here is sound.
    public func subscribeToCoreSimulator() throws {
        if notifier != nil { return }
        let (stream, continuation) = AsyncStream<CSBNotifierEvent>.makeStream()
        let queue = DispatchQueue(
            label: "com.deviceterm.daemon.devicenotifier",
            qos: .userInitiated
        )
        let notifier = try CSBDeviceNotifier.defaultNotifier(queue: queue) { event in
            continuation.yield(event)
        }
        self.notifier = notifier
        self.notifierContinuation = continuation
        self.notifierConsumer = Task { [weak self] in
            for await event in stream {
                await self?.handleNotifierEvent(event)
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
    }

    /// Dispatch a notification arriving from CoreSimulator into
    /// the right state mutation. The notifier wrapper only
    /// surfaces `.stateChanged` events with a populated UDID;
    /// `.other` and empty-UDID events drop here without effect.
    func handleNotifierEvent(_ event: CSBNotifierEvent) async {
        guard event.kind == .stateChanged, !event.udid.isEmpty else { return }
        switch event.newState {
        case .booted:
            await noteExternalBoot(udid: event.udid)

        case .shutdown:
            await noteExternalShutdown(udid: event.udid)

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
    func noteExternalBoot(udid: String) async {
        let normalized = udid.lowercased()
        await publishBootDebounced(udid: normalized)
    }

    /// External-shutdown path: a UDID transitioned to `.shutdown`.
    /// Drop any ownership record (the sim is gone regardless of
    /// who shut it down) and publish, debounced against a
    /// concurrent shim shutdown event for the same UDID.
    func noteExternalShutdown(udid: String) async {
        let normalized = udid.lowercased()
        ownership.removeValue(forKey: normalized)
        await publishShutdownDebounced(udid: normalized)
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
    private func publishBootDebounced(udid: String) async {
        let now = Date()
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

    /// Notification-path `deviceShutdown` publish, used by
    /// `noteExternalShutdown`. Mirror of `publishBootDebounced`.
    private func publishShutdownDebounced(udid: String) async {
        let now = Date()
        let lastAuth = recentAuthoritativeShutdowns[udid]
        let lastNotif = recentNotificationShutdowns[udid]
        recentNotificationShutdowns[udid] = now
        if let lastAuth, now.timeIntervalSince(lastAuth) < debounceWindow {
            return
        }
        if let lastNotif, now.timeIntervalSince(lastNotif) < debounceWindow {
            return
        }
        await eventBroker?.publish(.deviceShutdown(udid: udid), to: .everyone)
    }

    // MARK: - Internal helpers

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
