// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonEventsMethods: RPC handler for `daemon.events`.
//
// Wire shape:
//
//   daemon.events()                         → initial {ok:true}
//                                              + stream of `event` frames,
//                                                each frame's params is a
//                                                JSON-encoded DaemonEvent
//
// One subscription per RPC connection. The dispatcher tags every
// streamed `.event` frame with the original request's id so the client
// can multiplex, though the CLI only ever opens one subscription
// per connection.
//
// Auth: `daemon.events` is `.session`-scoped. The dispatcher rejects an
// unauthenticated connection (-32001) at the scope gate before this
// handler runs, and the handler tags the subscription with the caller's
// access principal: a `.session` sees only its own session's events plus
// `.everyone` (device booted/shutdown), while the validated GUI peer
// spans sessions. The two layers are distinct: the scope gate admits any
// authenticated session (GUI or agent); the audience filter (in
// EventBroker) is what promotes the GUI to see everything.

import DaemonProtocol
import Foundation

public enum DaemonEventsMethods {
    /// Subscription event method name. The RPC dispatcher tags each
    /// streamed frame with this name so the client can dispatch on
    /// it the same way it dispatches `pane.subscribe`'s
    /// `surface.changed` / `state.changed`.
    public static let eventName = "daemon.event"

    public static func subscribe(broker: EventBroker) -> MethodRegistry.SubscriptionHandler {
        { [broker] _, _ in
            // The `.session` scope gate has already rejected an
            // unauthenticated caller, so `fromCurrentDispatch` resolves to
            // `.session` or `.guiPeer` here; the `?? .session(UUID())`
            // fallback is unreachable past the gate and, being a fresh
            // random session, would see only `.everyone` events anyway.
            let principal = PaneAccessPrincipal.fromCurrentDispatch() ?? .session(UUID())
            let (subscriptionId, eventStream) = await broker.subscribe(as: principal)
            let (rpcStream, rpcContinuation) =
                AsyncStream<MethodRegistry.SubscriptionEvent>.makeStream()
            let encoder = JSONEncoder()
            // Adapter: drain the broker's typed stream, JSON-encode
            // each event, fan to the dispatcher's untyped wire stream.
            // Discarding the Task value (with `_ = adapter`) matches
            // PaneMethods.subscribe's pattern: the AsyncStream
            // termination closes the adapter via the `for await` loop.
            let adapter = Task {
                for await event in eventStream {
                    if let encoded = try? encoder.encode(event) {
                        rpcContinuation.yield(
                            MethodRegistry.SubscriptionEvent(
                            method: eventName,
                            params: encoded
                        )
                            )
                    }
                }
                rpcContinuation.finish()
            }
            _ = adapter

            let initialAck = try JSONEncoder().encode(RPCAck(success: true))
            return MethodRegistry.SubscriptionResult(
                initialResult: initialAck,
                events: rpcStream,
                onCancel: { [weak broker] in
                    Task { [weak broker] in
                        await broker?.unsubscribe(subscriptionId)
                    }
                }
            )
        }
    }
}
