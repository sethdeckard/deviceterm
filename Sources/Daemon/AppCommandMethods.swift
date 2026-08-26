// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// RPC handlers for the daemon side of the
/// back-channel.
///
/// Two `.validatedGUI` back-channel methods:
///   - `app.commands` (subscription): the GUI's perpetual stream.
///   - `app.commandResult` (one-shot): the GUI's per-command reply.
/// Both are pinned to a single connection: the subscription records the
/// subscriber's `connectionId`, and `app.commandResult` is accepted only
/// from that same connection (see `AppCommandCoordinator`). The
/// `.validatedGUI` scope keeps any UDS client out; the connection pin
/// keeps a second validated peer from *forging results* for the live
/// GUI, and generation-scoped teardown keeps a stale `onCancel` from
/// unsubscribing it. Subscription itself stays last-wins; a relaunched
/// GUI deliberately evicts the prior subscriber.
///
/// Plus the per-verb handlers (`tab.close`, `tab.info`,
/// `windows.list`, etc.) that build the typed params, publish to the
/// coordinator, await the GUI's reply, and either return the data
/// payload or surface a typed error to the CLI.
///
/// Role gating: handlers are tagged at registration time
/// (`.daemonWide` / `.session` / `.automationTab` / `.validatedGUI`);
/// the dispatcher's scope check in `RPCConnection.scopeCheck` /
/// `XPCConnection.scopeCheck` rejects before any of these run.
public enum AppCommandMethods {
    // MARK: - Subscription handler

    /// Producer for `app.commands`. Connects the coordinator's
    /// stream to the dispatcher's outbound write loop.
    public static func commandsSubscription(
        coordinator: AppCommandCoordinator
    ) -> MethodRegistry.SubscriptionHandler {
        { _, _ in
            // The back-channel is pinned to the subscribing connection.
            // The dispatcher binds `DispatchPeerContext.current` (with
            // the connection id) around the subscription handler, same
            // as the one-shot path; `.validatedGUI` guarantees an XPC
            // peer, so this is always present. Fail closed if it's ever
            // absent rather than registering an unpinned subscriber.
            guard let connectionId = DispatchPeerContext.current?.connectionId else {
                throw RPCMethodError(
                    code: RPCMethodError.scopeViolationCode,
                    message: "app.commands requires a connection-bound "
                        + "XPC subscription"
                )
            }
            let (stream, onCancel) = await coordinator.subscribe(
                connectionId: connectionId
            )
            // Map AppCommand → SubscriptionEvent. Wire frames carry
            // method = "app.command"; params = JSON-encoded command.
            let mapped = AsyncStream<MethodRegistry.SubscriptionEvent> { continuation in
                let bridge = Task {
                    for await command in stream {
                        let bytes = (try? JSONEncoder().encode(command))
                            ?? Data("{}".utf8)
                        continuation.yield(
                            MethodRegistry.SubscriptionEvent(
                                method: "app.command",
                                params: bytes
                            )
                        )
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in bridge.cancel() }
            }
            return MethodRegistry.SubscriptionResult(
                initialResult: Data(#"{"ok":true}"#.utf8),
                events: mapped,
                onCancel: onCancel
            )
        }
    }

    // MARK: - Result delivery

    /// One-shot `app.commandResult`, which the GUI calls per published command.
    public static func commandResult(
        coordinator: AppCommandCoordinator
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            // Pin delivery to the subscriber's connection. Fail closed
            // if no dispatch context (never for a validated XPC peer,
            // but a missing id must not be read as "no check").
            guard let connectionId = DispatchPeerContext.current?.connectionId else {
                throw RPCMethodError(
                    code: RPCMethodError.scopeViolationCode,
                    message: "app.commandResult requires a connection-bound "
                        + "XPC peer"
                )
            }
            let result = try JSONDecoder().decode(
                AppCommandResult.self,
                from: paramsJSON
            )
            guard await coordinator.deliverResult(
                result,
                from: connectionId
            ) else {
                throw RPCMethodError(
                    code: RPCMethodError.scopeViolationCode,
                    message: "app.commandResult accepted only from the "
                        + "active back-channel subscriber"
                )
            }
            return Data(#"{"ok":true}"#.utf8)
        }
    }

    // MARK: - Per-verb handlers

    /// Generic publish-and-relay helper used by every verb. Builds
    /// the AppCommand from the kind + caller-supplied params,
    /// publishes via the coordinator, waits, and turns the outcome
    /// into the wire response the CLI consumes.
    ///
    /// The originating session id (the calling tab's id, so the GUI
    /// can resolve `--tab current` / `--pane current`) rides on the
    /// task-local `SessionDispatchContext.originatingSessionId` that
    /// `RPCConnection.dispatch` binds before invoking the handler.
    /// `nil` for daemon-wide / unauthenticated callers (e.g.
    /// `windows.list` run from a stock terminal).
    ///
    /// `automationGrant` is the registry's store, the same one the scope
    /// check and capability advertising consult. It is read here rather
    /// than carried on a second task-local beside the session id: that
    /// one is bound at six sites across the two transports, and a
    /// seventh binding missed on any of them would silently refuse a
    /// real automation caller on whichever path it was missed. Nil store
    /// or an unparseable session id means no grant, so a registry built
    /// without automation fails closed.
    public static func publishVerb(
        kind: AppCommandKind,
        coordinator: AppCommandCoordinator,
        automationGrant: AutomationGrantStore?
    ) -> MethodRegistry.Handler {
        { paramsJSON in
            let originatingSessionId =
                SessionDispatchContext.originatingSessionId
            let sessionUUID = originatingSessionId
                .flatMap { UUID(uuidString: $0) }
            var hasGrant = false
            if let automationGrant, let sessionUUID {
                hasGrant = await automationGrant.hasGrant(sessionUUID)
            }
            let outcome = await coordinator.publishAndAwait(
                kind: kind,
                originatingSessionId: originatingSessionId,
                params: paramsJSON,
                originAutomationGrant: hasGrant
            )
            switch outcome {
            case .ok:
                return Data(#"{"ok":true}"#.utf8)

            case let .data(payload):
                return payload

            case let .error(code, message):
                // One number for "this needs a grant", whichever layer
                // refused. The dispatcher's own scope check already
                // answers `scopeViolationCode` for the flat verbs; a
                // GUI-side per-target refusal would otherwise arrive as
                // the generic -32099 with the reason buried in a
                // message string, leaving agents to substring-match to
                // tell two forms of the same answer apart. Every other
                // intent error keeps riding -32099 unchanged.
                if code == IntentErrorCode.automationRequired {
                    throw RPCMethodError.scopeViolation("\(code): \(message)")
                }
                throw RPCMethodError(code: -32_099, message: "\(code): \(message)")
            }
        }
    }
}
