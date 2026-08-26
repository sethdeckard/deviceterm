// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Name → handler routing for the RPC server.
///
/// Two handler kinds coexist:
///
///   - One-shot: `(paramsJSON) async throws -> resultJSON`. The
///     dispatcher sends a single `.response` envelope and is done.
///
///   - Subscription: `(paramsJSON, SubscriptionContext?) async throws ->
///     SubscriptionResult`. The handler returns the initial `.result` body plus an
///     `AsyncStream<SubscriptionEvent>` that the dispatcher drains,
///     emitting each yielded value as an `.event` envelope sharing the
///     original request's `id`. The handler also returns an
///     `onCancel` closure that the dispatcher calls when the client
///     disconnects or the connection otherwise tears the subscription
///     down: that closure is the producer's hook to release any
///     resources (e.g. unsubscribe from a coordinator).
///
/// Method handlers take the raw `params` JSON bytes (or `"{}"` when
/// the request had no body, per `RPCConnection`'s normalization) and
/// return raw JSON bytes for the body of whatever envelope they emit.
/// Each handler decodes its own typed `Params` and encodes its own
/// typed `Result`. The registry is body-shape-agnostic so adding
/// methods doesn't require any envelope-layer changes.
///
/// Each entry is tagged with a `MethodScope`. Both dispatchers,
/// `RPCConnection` and `XPCConnection`, read the tag and pre-check the
/// connection's auth state before invoking the handler: `.session` requires
/// `authenticatedSession != nil`; `.automationTab` additionally
/// requires a live automation grant for the session (from the
/// `AutomationGrantStore`, checked per request, not a role);
/// `.validatedGUI` requires an XPC peer that validated against the
/// daemon's signature (the GUI back-channel). Handlers see only
/// requests that have already passed those checks.
/// `methodsForRole(_:)` mirrors the same rule on the read side so
/// `daemon.capabilities` advertising stays in lockstep with what
/// the dispatcher actually accepts.
public struct MethodRegistry: Sendable {
    public typealias Handler = @Sendable (_ paramsJSON: Data) async throws -> Data
    /// A subscription handler. The transport-created `SubscriptionContext`
    /// (nil over UDS) carries the correlation token, the registering
    /// connection, and the lifecycle box; only `pane.subscribe` consults
    /// it. The non-pane subscriptions (events, app.commands) ignore it.
    public typealias SubscriptionHandler =
        @Sendable (_ paramsJSON: Data, _ context: SubscriptionContext?) async throws -> SubscriptionResult

    /// What a subscription handler returns: the initial `.result`
    /// body, the stream of subsequent events, and a hook the
    /// dispatcher calls when the subscription is torn down.
    ///
    /// `onCancel` is the pool-free producer unsubscribe: it tears down
    /// the coordinator subscriber and the event adapter, and runs for
    /// every transport (UDS, XPC sim, XPC device). The device pool
    /// teardown rides `SubscriptionContext.lifecycle`, layered on top.
    public struct SubscriptionResult: Sendable {
        public let initialResult: Data
        public let events: AsyncStream<SubscriptionEvent>
        public let onCancel: @Sendable () -> Void

        public init(
            initialResult: Data,
            events: AsyncStream<SubscriptionEvent>,
            onCancel: @escaping @Sendable () -> Void
        ) {
            self.initialResult = initialResult
            self.events = events
            self.onCancel = onCancel
        }
    }

    /// One streamed event: the method name the client will see on the
    /// wire (`surface.changed`, `state.changed`, etc.) and its
    /// `params` payload as JSON bytes. Each event yielded into a
    /// subscription's `events` stream becomes one `.event` envelope.
    public struct SubscriptionEvent: Sendable, Equatable {
        public let method: String
        public let params: Data

        public init(method: String, params: Data) {
            self.method = method
            self.params = params
        }
    }

    /// A one-shot handler tagged with its `MethodScope`. Construct
    /// via the `.daemonWide(_:)` / `.session(_:)` /
    /// `.automationTab(_:)` / `.validatedGUI(_:)` factories below for
    /// readable registration tables.
    public struct ScopedHandler: Sendable {
        public let scope: MethodScope
        public let handler: Handler

        public init(scope: MethodScope, handler: @escaping Handler) {
            self.scope = scope
            self.handler = handler
        }
    }

    /// A subscription handler tagged with its `MethodScope`.
    public struct ScopedSubscription: Sendable {
        public let scope: MethodScope
        public let handler: SubscriptionHandler

        public init(
            scope: MethodScope,
            handler: @escaping SubscriptionHandler
        ) {
            self.scope = scope
            self.handler = handler
        }
    }

    /// Resolved kind for a registered method name. Returned by
    /// `lookup(_:)` so the dispatcher can switch on the kind without
    /// peeking at two dictionaries.
    public enum Resolved: Sendable {
        case oneShot(Handler)
        case subscription(SubscriptionHandler)
    }

    private let oneShot: [String: ScopedHandler]
    private let subscriptions: [String: ScopedSubscription]

    /// The provenance context this registry was built against: the SAME
    /// instance the `session.bindTerminal` handler binds into. The servers
    /// (`RPCServer`/`XPCServer`) read this off the registry rather than taking
    /// a separate `provenance:` parameter, so the store the lookup reads, the
    /// store the close path revokes, and the store `bindTerminal` writes cannot
    /// diverge: there is exactly one context, carried by the registry. Nil when
    /// the registry doesn't exercise terminal provenance (an authenticating
    /// server then fails its `provenance != nil` precondition).
    public let provenance: ProvenanceContext?

    /// The live automation-grant store this registry was built against: the
    /// SAME instance the `automation.grant`/`.revoke` handlers mutate, the
    /// `daemon.capabilities` advertiser reads, and the session close path
    /// revokes from. Both servers (`RPCServer`/`XPCServer`) read this off the
    /// registry rather than taking a separate `automationGrantStore:`
    /// parameter, so the ledger advertising consults, the ledger the two
    /// dispatchers' `.automationTab` scope checks consult, and the ledger the
    /// handlers write cannot diverge: there is exactly one store, carried by the
    /// registry, mirroring `provenance`. Nil when the registry doesn't exercise
    /// automation grants (the scope check then fails closed).
    public let automationGrant: AutomationGrantStore?

    /// Method names this registry knows about. Used by diagnostic
    /// endpoints and probe-style tooling. Sorted for stable output.
    public var methodNames: [String] {
        (Array(oneShot.keys) + Array(subscriptions.keys)).sorted()
    }

    public init(
        handlers: [String: ScopedHandler] = [:],
        subscriptions: [String: ScopedSubscription] = [:],
        provenance: ProvenanceContext? = nil,
        automationGrant: AutomationGrantStore? = nil
    ) {
        self.oneShot = handlers
        self.subscriptions = subscriptions
        self.provenance = provenance
        self.automationGrant = automationGrant
    }

    /// Look up a method by name. Returns `nil` if no method is
    /// registered under that name; otherwise returns the resolved
    /// kind so the dispatcher can run it.
    public func lookup(_ method: String) -> Resolved? {
        if let scoped = oneShot[method] { return .oneShot(scoped.handler) }
        if let scoped = subscriptions[method] {
            return .subscription(scoped.handler)
        }
        return nil
    }

    /// One-shot handler accessor preserved for call sites and tests
    /// that only care about non-streaming methods.
    public func handler(for method: String) -> Handler? {
        oneShot[method]?.handler
    }

    /// The scope declared at registration time for `method`. Returns
    /// nil if the method isn't registered.
    public func scope(of method: String) -> MethodScope? {
        oneShot[method]?.scope ?? subscriptions[method]?.scope
    }

    /// Method names visible to a caller in the given `role`, sorted
    /// for stable output. The source of truth for
    /// `daemon.capabilities`'s `allowedMethods` field.
    ///
    ///   - `nil`: no session creds (out-of-tab caller). Returns
    ///     `.daemonWide` methods only. Lets `deviceterm --help` from a
    ///     stock terminal show the unauthenticated subset.
    ///   - `.agent` / `.automation`: in-tab session. Returns
    ///     `.daemonWide` + `.session`. `.automationTab` methods are
    ///     added purely from `automationTabReachable` (the session's
    ///     live grant), NOT from the role. So a granted `.agent` sees
    ///     them and an ungranted `.automation` does not.
    ///
    /// `.validatedGUI` methods are added orthogonally when
    /// `validatedGUIReachable` is true (the peer validated against the
    /// daemon's signature over XPC).
    public func methodsForRole(
        _ role: SessionRole?,
        automationTabReachable: Bool,
        validatedGUIReachable: Bool
    ) -> [String] {
        let allowed = MethodScope.allowedFor(
            role: role,
            automationTabReachable: automationTabReachable,
            validatedGUIReachable: validatedGUIReachable
        )
        let oneShotNames = oneShot
            .filter { allowed.contains($0.value.scope) }
            .map(\.key)
        let subNames = subscriptions
            .filter { allowed.contains($0.value.scope) }
            .map(\.key)
        return (oneShotNames + subNames).sorted()
    }
}

// MARK: - Convenience factories

public extension MethodRegistry.ScopedHandler {
    /// Daemon-wide: anyone with socket access. No auth.
    static func daemonWide(
        _ handler: @escaping MethodRegistry.Handler
    ) -> Self {
        .init(scope: .daemonWide, handler: handler)
    }

    /// Session-scoped: requires an authenticated connection: a valid cap on a
    /// live session PLUS the caller's kernel provenance (owner or bound
    /// terminal), re-checked per request. Either role passes; the cap alone
    /// is insufficient. A handler that also takes payload `(sessionId, cap)`
    /// confirms the target equals the connection's own session.
    static func session(
        _ handler: @escaping MethodRegistry.Handler
    ) -> Self {
        .init(scope: .session, handler: handler)
    }

    /// Automation-tab-only: dispatcher requires the connection to be
    /// authenticated AND the session to hold a **live automation grant**
    /// (from the `AutomationGrantStore`, checked per request); otherwise
    /// it rejects with `error.scope_violation` before the handler runs.
    /// Authority is the grant, not the role: a granted `.agent` reaches it,
    /// an ungranted `.automation` does not. `tab.sendInput` and
    /// `tab.capture` carry this scope. Reachable over BOTH transports for a
    /// granted session: the GUI's validated XPC connection, and UDS from the
    /// CLI inside a granted tab. A UDS session authenticates via cap + kernel
    /// terminal-process provenance, so the grant rests on a real identity, not
    /// the cap alone. Escalation stays XPC-GUI-only: a UDS caller can neither
    /// mint an automation role nor issue itself a grant.
    static func automationTab(
        _ handler: @escaping MethodRegistry.Handler
    ) -> Self {
        .init(scope: .automationTab, handler: handler)
    }

    /// Validated-GUI-only: reachable only over XPC from a peer whose
    /// audit token validates against the daemon's own signature. Needs
    /// no authenticated session and no role: the audit token is the
    /// trust anchor. The GUI back-channel (`app.commandResult`) carries
    /// this scope.
    static func validatedGUI(
        _ handler: @escaping MethodRegistry.Handler
    ) -> Self {
        .init(scope: .validatedGUI, handler: handler)
    }
}

public extension MethodRegistry.ScopedSubscription {
    static func daemonWide(
        _ handler: @escaping MethodRegistry.SubscriptionHandler
    ) -> Self {
        .init(scope: .daemonWide, handler: handler)
    }

    static func session(
        _ handler: @escaping MethodRegistry.SubscriptionHandler
    ) -> Self {
        .init(scope: .session, handler: handler)
    }

    /// Validated-GUI-only subscription (the `app.commands` back-channel
    /// stream). See `ScopedHandler.validatedGUI(_:)`.
    static func validatedGUI(
        _ handler: @escaping MethodRegistry.SubscriptionHandler
    ) -> Self {
        .init(scope: .validatedGUI, handler: handler)
    }
}
