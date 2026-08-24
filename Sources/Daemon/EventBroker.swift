// SPDX-License-Identifier: GPL-3.0-or-later
//
// EventBroker: daemon-wide pub/sub for `DaemonEvent`s, audience-filtered.
//
// One broker per daemon. Subscribers (the `daemon.events` RPC handler)
// call `subscribe(as:)` with their access principal to get an
// `AsyncStream<DaemonEvent>`; publishers (PaneCoordinator,
// DeviceCoordinator, SessionManager) call `publish(_:to:)` from inside
// their actors, naming the event's audience. Fan-out is "best-effort with
// backpressure-by-AsyncStream-buffer": a slow consumer sees continuation
// buffering per AsyncStream's defaults but won't block publishers (`yield`
// is non-blocking against the `.unbounded`-style stream `makeStream`
// returns by default).
//
// Audience filtering mirrors the pane gate: a `.session` principal sees
// `.everyone`, its own `.session` audience, and any `.sessions` audience
// containing its session id (and, when the subscriber is pinned, its
// incarnation); the validated GUI peer (`.guiPeer`) spans sessions and sees
// every event. "May you drive this pane" and "may you
// see its events" have the same answer for the same reason, so the
// principal type is shared rather than duplicated.
//
// Subscriber registration is `actor`-isolated per AGENTS.md's "shared
// daemon state lives behind actors" rule. The continuation's
// `onTermination` hook releases the subscriber when the consumer cancels
// (drops the stream or the RPC connection closes); the dispatcher's
// `onCancel` hook calls `unsubscribe(_:)` explicitly to belt-and-suspenders
// the cleanup.

import DaemonProtocol
import Foundation

public actor EventBroker {
    /// A live subscriber: its stream continuation plus the access
    /// principal that decides which audiences reach it.
    private struct Subscriber {
        let continuation: AsyncStream<DaemonEvent>.Continuation
        let principal: PaneAccessPrincipal
    }

    private var subscribers: [UUID: Subscriber] = [:]
    /// The event-stream INCARNATION currently admitted per session id, stamped
    /// by `reactivateSession(_:incarnation:)` when the ordered lifecycle makes
    /// that incarnation `.ready` and REMOVED by `finishSession` (retirement).
    /// It holds an entry ONLY for a currently-live session, so ordinary (and
    /// adversarial) create/close churn can't grow it for the daemon's
    /// lifetime: a closed id's entry is gone, not tombstoned. It is the sole
    /// producer-side ABA gate: an incarnation-pinned `.session(id, reqInc)`
    /// subscribe is admitted only when `acceptedIncarnation[id] == reqInc`, so
    /// a request authorized under incarnation G that resumes after the same
    /// UUID was closed (entry removed) or restored at G+1 (entry now G+1) is
    /// refused with a terminal stream. A closed id is additionally rejected at
    /// the dispatch scope check (admission `.absent`); this is the backstop for
    /// the narrow parked-past-close window.
    private var acceptedIncarnation: [UUID: UInt64] = [:]

    /// Number of live subscribers. Diagnostic.
    public var subscriberCount: Int { subscribers.count }

    public init() {}

    /// The audience rule: deliver iff the principal is the validated GUI
    /// peer, the audience is `.everyone`, the audience is the subscriber's
    /// own `.session`, or a `.sessions` audience contains the subscriber's
    /// session id (matched on incarnation too when the subscriber is
    /// pinned).
    private static func delivers(to principal: PaneAccessPrincipal, audience: EventAudience) -> Bool {
        switch principal {
        case .guiPeer:
            return true

        case let .session(sessionId, subscriberIncarnation):
            switch audience {
            case .everyone:
                return true

            case let .session(target):
                return sessionId == target

            case let .sessions(targets):
                return targets.contains {
                    $0.sessionId == sessionId
                        && (subscriberIncarnation == nil || $0.incarnation == subscriberIncarnation)
                }
            }
        }
    }

    /// Test-only: whether a session id is currently retired, i.e. holds no
    /// admissible incarnation (never activated, or finished and not
    /// reactivated).
    func isRetired(_ sessionId: UUID) -> Bool { acceptedIncarnation[sessionId] == nil }

    /// Whether a `.session(sessionId, requestIncarnation)` subscribe must be
    /// refused. An incarnation-pinned request is admitted only when it matches
    /// the id's currently-accepted incarnation, so a request that resumes
    /// after the id was finished (no accepted incarnation) or restored at a new
    /// incarnation is refused. A `nil` request incarnation (an internal/test
    /// caller, or a standalone broker with no lifecycle driving it) is
    /// un-pinned and admitted; a production daemon.events subscribe always
    /// carries the live incarnation from the scope check.
    private func isRefused(sessionId: UUID, requestIncarnation: UInt64?) -> Bool {
        guard let requestIncarnation else { return false }
        return acceptedIncarnation[sessionId] != requestIncarnation
    }

    /// Register a subscriber tagged with its access `principal` and return
    /// its id + an AsyncStream to consume. The id lets the RPC dispatcher
    /// call `unsubscribe(_:)` on connection teardown; consumers that just
    /// drop the stream also clean up via the continuation's `onTermination`
    /// hook. The principal decides (in `publish`) which events it sees.
    func subscribe(
        as principal: PaneAccessPrincipal
    ) -> (subscriptionId: UUID, stream: AsyncStream<DaemonEvent>) {
        let subscriptionId = UUID()
        let (stream, continuation) = AsyncStream<DaemonEvent>.makeStream()
        // Producer-side admission fence. A `.session(id, reqInc)` subscribe is
        // refused with a terminal, immediately-finished stream (and NO live
        // subscriber) when the id is retired and not yet reactivated, OR when
        // its request incarnation doesn't match the currently-accepted one, so
        // a subscribe that slipped past the dispatch scope check and resumed
        // after the session closed (or after a *different* incarnation was
        // restored under the same UUID) mints no surviving authority.
        // `.guiPeer` is never gated (it spans sessions); a `nil` request
        // incarnation is un-pinned (matches any accepted incarnation).
        if case let .session(sessionId, requestIncarnation) = principal,
            isRefused(sessionId: sessionId, requestIncarnation: requestIncarnation) {
            continuation.finish()
            return (subscriptionId, stream)
        }
        subscribers[subscriptionId] = Subscriber(continuation: continuation, principal: principal)
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeSubscriber(subscriptionId)
            }
        }
        return (subscriptionId, stream)
    }

    /// Atomically close a session's event stream: in ONE actor turn (no
    /// interior suspension), yield `event` to every subscriber the
    /// `.session(sessionId)` audience accepts (which includes `.guiPeer`,
    /// so the GUI receives the final `.sessionClosed` too), then RETIRE the
    /// id and remove + `finish()` only the subscribers whose principal is
    /// exactly `.session(sessionId)`, leaving `.guiPeer` (and every other
    /// session's) subscription intact. Because retirement and the removal
    /// happen in the same turn as the final yield, `.sessionClosed` is
    /// genuinely the last permitted yield on the closing session's stream:
    /// a publication linearized before this may precede the close; one
    /// linearized after reaches no removed subscriber, and a subscribe that
    /// resumes after this finds the id retired. Runs only inside the
    /// destructive session-finalize transition.
    func finishSession(_ sessionId: UUID, withFinalEvent event: DaemonEvent) {
        // (1) Deliver the final event under the normal audience rule (reaches
        // the closing session's own subscribers AND the GUI peer).
        for subscriber in subscribers.values
        where Self.delivers(to: subscriber.principal, audience: .session(sessionId)) {
            subscriber.continuation.yield(event)
        }
        // (2) Retire the id by dropping its accepted incarnation, so a later
        // incarnation-pinned `.session(sessionId, *)` subscribe is refused
        // until a restored incarnation reactivates it. Removing the entry (vs
        // tombstoning) keeps the map bounded to live sessions only.
        acceptedIncarnation.removeValue(forKey: sessionId)
        // (3) Remove + finish only the exactly-`.session(sessionId)`
        // subscribers; spare `.guiPeer` and other sessions.
        let doomed = subscribers.compactMap { id, subscriber -> UUID? in
            if case let .session(sid, _) = subscriber.principal, sid == sessionId { return id }
            return nil
        }
        for id in doomed {
            if let subscriber = subscribers.removeValue(forKey: id) {
                subscriber.continuation.finish()
            }
        }
    }

    /// Reopen a session id at a specific incarnation so `.session(id,
    /// incarnation)` subscribes are admitted again. Driven ONLY by the ordered
    /// per-id lifecycle transition when an incarnation of the id reaches
    /// `.ready` (a fresh create, or a restored incarnation), never by a raced
    /// subscribe. Stamps the accepted incarnation, so a subsequent subscribe
    /// carrying a *different* (older) incarnation is refused. Idempotent.
    func reactivateSession(_ sessionId: UUID, incarnation: UInt64) {
        acceptedIncarnation[sessionId] = incarnation
    }

    /// Drop a subscriber, finishing its stream. Idempotent: calling
    /// twice on the same id is a no-op.
    public func unsubscribe(_ subscriptionId: UUID) {
        removeSubscriber(subscriptionId)
    }

    /// Fan `event` out to every subscriber the `audience` reaches: the
    /// validated GUI peer (spans sessions), a `.session` subscriber whose
    /// session matches a `.session` audience, and every subscriber for
    /// `.everyone`. `yield` is non-blocking; slow consumers see continuation
    /// buffering per AsyncStream's defaults rather than blocking the
    /// publisher.
    func publish(_ event: DaemonEvent, to audience: EventAudience) {
        for subscriber in subscribers.values where Self.delivers(to: subscriber.principal, audience: audience) {
            subscriber.continuation.yield(event)
        }
    }

    private func removeSubscriber(_ subscriptionId: UUID) {
        guard let subscriber = subscribers.removeValue(forKey: subscriptionId) else {
            return
        }
        subscriber.continuation.finish()
    }
}
