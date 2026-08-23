// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonMethods: the `daemon.*` method namespace and the registry
// binding every RPC method to its handler and scope.
//
// `daemon.shutdown` is `.validatedGUI`, XPC-only: its sole production
// use is terminating an incompatible old helper after a definite
// update-related wire mismatch (Sparkle can swap DeviceTerm.app while a
// daemon holding an owned booted sim stays alive, so quitting the GUI
// does not guarantee the daemon exits). No UDS caller, session
// credential, automation grant, or unvalidated XPC peer can reach it,
// closing the unauthenticated confused-deputy surface. It does not
// claim to prevent every same-uid, signal-level DoS. Ordinary daemon
// lifecycle still uses idle exit.

import DaemonProtocol
import Foundation

public enum DaemonInfo {
    /// The daemon's wire-version string. Returned in `daemon.ping`
    /// responses and compared by the GUI client against its own
    /// `DaemonProtocolInfo.wireVersion` (they mirror each other). A
    /// definite mismatch drives update recovery: the GUI issues
    /// `daemon.shutdown` to the incompatible daemon, awaits the ack,
    /// then surfaces the quit/reopen remediation so the next launch
    /// starts the helper from the updated bundle.
    public static let version = DaemonProtocolInfo.wireVersion
}

public enum DaemonMethods {
    /// Closure the daemon binary supplies to actually terminate the
    /// process. Library code stays AppKit-free; the executable
    /// wrapper passes a closure that hops to `@MainActor` and calls
    /// `NSApp.terminate(nil)`. Tests pass a recorder closure.
    public typealias ShutdownTrigger = @Sendable () async -> Void

    /// Response payload for `daemon.ping`.
    public struct PingResponse: Codable, Sendable, Equatable {
        public let version: String
        public let pid: Int32
    }

    /// Response payload for `daemon.shutdown`. Matches the shared
    /// `{ok: true}` shape used by `session.close`, `pane.close`, etc.
    public struct ShutdownResponse: Codable, Sendable, Equatable {
        private enum CodingKeys: String, CodingKey {
            case success = "ok"
        }
        public let success: Bool
    }

    /// Brief delay between sending the `daemon.shutdown` ack and
    /// firing the terminate trigger. Without it, the runloop can
    /// tear down before `writeAll` finishes flushing the response
    /// frame, and the client sees a closed connection instead of
    /// the `{ok: true}` ack. A 100 ms grace allows the response frame
    /// to flush before termination begins.
    public static let shutdownAckGraceMs: UInt64 = 100

    /// Liveness + identity probe. No params; returns `{version, pid}`.
    /// Used by both the GUI's `DaemonClient` (for the version
    /// handshake) and by tests as the simplest possible round trip.
    public static let ping: MethodRegistry.Handler = { _ in
        let response = PingResponse(
            version: DaemonInfo.version,
            pid: ProcessInfo.processInfo.processIdentifier
        )
        return try JSONEncoder().encode(response)
    }

    /// `daemon.shutdown`: `.validatedGUI`, XPC-only (see the file
    /// header). Returns `{ok: true}`, then fires the caller-supplied
    /// terminate trigger after a brief delay so the ack flushes to the
    /// client first: the delay is what lets the GUI distinguish an
    /// accepted shutdown from a transport loss. Authorization is the
    /// dispatcher's `.validatedGUI` scope gate (the peer's audit-token
    /// signature check); the handler itself performs no peer validation.
    /// The production trigger calls `NSApp.terminate(nil)` after the
    /// acknowledgement grace period, so socket/tunnel cleanup executes on the
    /// way out.
    public static func shutdown(trigger: @escaping ShutdownTrigger) -> MethodRegistry.Handler {
        { _ in
            let response = try JSONEncoder().encode(ShutdownResponse(success: true))
            Task.detached {
                try? await Task.sleep(
                    nanoseconds: shutdownAckGraceMs * 1_000_000
                )
                await trigger()
            }
            return response
        }
    }

    /// `daemon.capabilities`. Daemon-wide. Returns the
    /// caller's role + the methods they may invoke + the wire and
    /// linkage-policy versions. Works with or without session creds:
    /// out-of-tab callers get `role: nil` + the daemon-wide subset of
    /// methods, so `deviceterm --help` from a stock terminal succeeds
    /// without authentication.
    ///
    /// Takes the `methodsForRole` closure rather than a
    /// `MethodRegistry` ref to sidestep the self-reference: the
    /// registry includes `daemon.capabilities` itself, but the
    /// handler is constructed before the registry exists. The
    /// closure captures a precomputed `(name, scope)` table that
    /// already includes capabilities, so the response correctly
    /// advertises self-callability.
    public static func capabilities(
        automationGrantStore: AutomationGrantStore,
        methodsForRole: @escaping @Sendable (
            _ role: SessionRole?,
            _ automationTabReachable: Bool,
            _ validatedGUIReachable: Bool
        ) -> [String]
    ) -> MethodRegistry.ScopedHandler {
        .daemonWide { _ in
            // Advertise capabilities for the PROVENANCE-CHECKED connection, not
            // for a payload-supplied `(sessionId, cap)`. The wire cap is
            // readable by any same-uid process (`ps -E`), so honoring payload
            // creds here would let an attacker authenticated as its own session
            // paste a victim's cap and learn the victim's role/grant advertising.
            // The connection's `authenticatedSession` was installed only after
            // the provenance gate passed, so it is the trustworthy principal.
            // An unauthenticated connection sees the daemon-wide subset (nil
            // role): `daemon.capabilities` stays a discovery method.
            let context = DispatchPeerContext.current
            let session = context?.authenticatedSession
            let role = session?.role
            let sessionId = session?.id
            let transport = context?.transport ?? .uds
            let validatedGUI = context?.validatedGUIPeer ?? false
            let hasGrant = if let sessionId {
                await automationGrantStore.hasGrant(sessionId)
            } else {
                false
            }
            let automationTabReachable = MethodScope.automationTabReachable(
                hasGrant: hasGrant,
                transport: transport,
                validatedGUI: validatedGUI
            )
            let validatedGUIReachable = MethodScope.validatedGUIReachable(
                transport: transport,
                validatedGUI: validatedGUI
            )
            let response = DaemonCapabilitiesResponse(
                role: role,
                allowedMethods: methodsForRole(
                    role,
                    automationTabReachable,
                    validatedGUIReachable
                ),
                wireVersion: DaemonInfo.version,
                linkagePolicyVersion: LinkagePolicy.currentVersion
            )
            return try JSONEncoder().encode(response)
        }
    }

    /// Apply scope filtering to a precomputed `(name, scope)` table.
    /// Pure logic: used by `defaultRegistry(...)` to feed the
    /// `capabilities` handler a closure that already includes
    /// `daemon.capabilities` in its result without needing a
    /// registry back-reference. Mirrors
    /// `MethodRegistry.methodsForRole(_:)` shape; both paths must
    /// return the same answer for the same scopes: the
    /// `daemon.capabilities` registry-drift guard pins that.
    static func methodsForRole(
        _ role: SessionRole?,
        automationTabReachable: Bool,
        validatedGUIReachable: Bool,
        scopes: [(name: String, scope: MethodScope)]
    ) -> [String] {
        let allowed = MethodScope.allowedFor(
            role: role,
            automationTabReachable: automationTabReachable,
            validatedGUIReachable: validatedGUIReachable
        )
        return scopes
            .filter { allowed.contains($0.scope) }
            .map(\.name)
            .sorted()
    }

    /// Default registry shipped with the daemon. Wires the
    /// `daemon.*` / `session.*` / `tabs.*` / `device.*` / `pane.*`
    /// methods against shared service actors. The actors are
    /// injected (rather than constructed inside) so the daemon
    /// binary can hold strong references to them and tests can
    /// introspect / fixture-time them.
    ///
    /// Each entry is tagged with a `MethodScope` via the
    /// `.daemonWide(_:)` / `.session(_:)` / `.automationTab(_:)` /
    /// `.validatedGUI(_:)` factories on `ScopedHandler`.
    /// `daemon.capabilities` registers
    /// last with a closure that captures a snapshot of the
    /// `(name, scope)` table including itself: that way the
    /// response correctly advertises self-callability without a
    /// circular registry reference.
    public static func defaultRegistry(
        sessionManager: SessionManager,
        deviceCoordinator: DeviceCoordinator,
        paneCoordinator: PaneCoordinator,
        physicalDeviceCoordinator: PhysicalDeviceCoordinator = PhysicalDeviceCoordinator(),
        eventBroker: EventBroker = EventBroker(),
        appCommandCoordinator: AppCommandCoordinator = AppCommandCoordinator(),
        provenance: ProvenanceContext? = nil,
        shutdownTrigger: @escaping ShutdownTrigger = {}
    ) -> MethodRegistry {
        // The grant ledger has a single owner: the session manager. Sourcing it
        // here (rather than taking a separate parameter) guarantees the store
        // the grant/revoke handlers write, the store both dispatchers' scope
        // checks read, the store `daemon.capabilities` advertises from, and the
        // store the session-close path revokes from are all THE SAME instance:
        // it is structurally impossible to hand the registry a store that
        // diverges from the manager's revocation store. Mirrors how the
        // terminal-anchor store is sourced from the provenance context/manager.
        let automationGrantStore = sessionManager.automationGrantStore
        // The `session.bindTerminal` handler MUST bind into the SAME store the
        // connections' provenance lookup reads and the XPC close path revokes:
        // otherwise a bind lands in a store the lookup can't see. When a
        // `provenance` context is supplied (production always does), enforce
        // that it was derived from THIS manager, then source the bind store
        // from it: so the registry and the servers can't be handed contexts
        // built from different managers. When absent (tests that don't exercise
        // the full path), fall back to the manager's own store, which the
        // `ProvenanceContext` would resolve to anyway.
        if let provenance {
            precondition(
                provenance.sessionManager === sessionManager,
                "defaultRegistry's sessionManager must match the ProvenanceContext's"
            )
        }
        let terminalAnchorStore = provenance?.anchorStore ?? sessionManager.terminalAnchorStore
        var handlers: [String: MethodRegistry.ScopedHandler] = [
            RPCMethod.daemonPing.rawValue: .daemonWide(ping),
            RPCMethod.daemonShutdown.rawValue:
                .validatedGUI(shutdown(trigger: shutdownTrigger)),
            RPCMethod.sessionCreate.rawValue:
                .daemonWide(SessionMethods.create(using: sessionManager)),
            // `session.authenticate` is dispatcher-intercepted in
            // `RPCConnection` because the per-connection auth state
            // it mutates isn't reachable from a regular handler.
            // This stub handler is unreachable; it exists so the
            // method appears in `methodNames` (registry-drift guard)
            // and in `methodsForRole(_:)` (daemon.capabilities
            // advertising) without a parallel listing path.
            RPCMethod.sessionAuthenticate.rawValue: .daemonWide { _ in
                throw RPCMethodError(
                    code: RPCErrorCode.serverError,
                    message: "session.authenticate is dispatcher-handled; "
                        + "this stub should never run"
                )
            },
            RPCMethod.sessionBindTerminal.rawValue:
                .validatedGUI(SessionMethods.bindTerminal(store: terminalAnchorStore)),
            RPCMethod.sessionClose.rawValue:
                .session(
                    SessionMethods.close(using: sessionManager) { sessionId, mode in
                        await deviceCoordinator.noteSessionClosing(sessionId, mode: mode)
                    }
                ),
            RPCMethod.sessionSetProtectedBatch.rawValue:
                .validatedGUI(SessionMethods.setProtectedBatch(using: sessionManager)),
            RPCMethod.sessionRestoreBatch.rawValue:
                .validatedGUI(SessionMethods.restoreBatch(using: sessionManager)),
            RPCMethod.sessionProtectionSnapshot.rawValue:
                .validatedGUI(SessionMethods.protectionSnapshot(using: sessionManager)),
            RPCMethod.sessionSetDisplayTitle.rawValue:
                .validatedGUI(SessionMethods.setDisplayTitle(using: sessionManager)),
            RPCMethod.automationGrant.rawValue:
                .validatedGUI(AutomationMethods.grant(store: automationGrantStore)),
            RPCMethod.automationRevoke.rawValue:
                .validatedGUI(AutomationMethods.revoke(store: automationGrantStore)),
            RPCMethod.tabsList.rawValue:
                .daemonWide(SessionMethods.tabsList(using: sessionManager)),
            RPCMethod.panesList.rawValue: .session(
                PaneMethods.panesList(
                paneCoordinator: paneCoordinator,
                sessionManager: sessionManager
            )
                ),
            // The shim binary speaks this from inside a tab (it has
            // session creds via env); the handler validates them.
            // Tagged `.session` rather than `.daemonWide` so the
            // capabilities advertising matches the actual
            // authentication requirement: an out-of-tab caller
            // would be rejected by the handler anyway, and shouldn't
            // see it in their allowedMethods list.
            RPCMethod.shimEvent.rawValue: .session(
                ShimMethods.event(
                sessionManager: sessionManager,
                deviceCoordinator: deviceCoordinator,
                paneCoordinator: paneCoordinator,
                physicalDeviceCoordinator: physicalDeviceCoordinator,
                appCommandCoordinator: appCommandCoordinator
            )
                ),
            RPCMethod.deviceList.rawValue:
                .daemonWide(DeviceMethods.list(using: deviceCoordinator)),
            RPCMethod.deviceBoot.rawValue: .session(
                DeviceMethods.boot(
                coordinator: deviceCoordinator,
                sessionManager: sessionManager
            )
                ),
            RPCMethod.deviceShutdown.rawValue: .daemonWide(
                DeviceMethods.shutdown(
                using: deviceCoordinator,
                paneCoordinator: paneCoordinator
            )
                ),
            RPCMethod.deviceAttach.rawValue: .session(
                DeviceMethods.attach(
                coordinator: deviceCoordinator,
                paneCoordinator: paneCoordinator,
                sessionManager: sessionManager
            )
                ),
            RPCMethod.deviceReconcileBootClaim.rawValue: .validatedGUI(
                DeviceMethods.reconcileBootClaim(
                    coordinator: deviceCoordinator,
                    sessionManager: sessionManager
                )
            ),
            RPCMethod.deviceRestoreOwnership.rawValue: .validatedGUI(
                DeviceMethods.restoreOwnership(
                coordinator: deviceCoordinator,
                sessionManager: sessionManager
            )
                ),
            RPCMethod.physicalDeviceList.rawValue: .daemonWide(
                PhysicalDeviceMethods.list(coordinator: physicalDeviceCoordinator)
            ),
            RPCMethod.physicalDeviceAttach.rawValue: .session(
                PhysicalDeviceMethods.attach(
                physicalDeviceCoordinator: physicalDeviceCoordinator,
                paneCoordinator: paneCoordinator,
                sessionManager: sessionManager
            )
                ),
            RPCMethod.devicesList.rawValue: .session(
                PhysicalDeviceMethods.devicesList(
                deviceCoordinator: deviceCoordinator,
                physicalDeviceCoordinator: physicalDeviceCoordinator,
                paneCoordinator: paneCoordinator,
                sessionManager: sessionManager
            )
                ),
            RPCMethod.paneCreate.rawValue: .session(
                PaneMethods.create(
                paneCoordinator: paneCoordinator,
                sessionManager: sessionManager
            )
                ),
            RPCMethod.paneCloseById.rawValue: .session(
                PaneMethods.close(
                paneCoordinator: paneCoordinator,
                deviceCoordinator: deviceCoordinator,
                physicalDeviceCoordinator: physicalDeviceCoordinator
            )
                ),
            RPCMethod.paneInputTap.rawValue:
                .session(PaneMethods.tap(paneCoordinator: paneCoordinator)),
            RPCMethod.paneInputTouch.rawValue:
                .session(PaneMethods.touch(paneCoordinator: paneCoordinator)),
            RPCMethod.paneInputSwipe.rawValue:
                .session(PaneMethods.swipe(paneCoordinator: paneCoordinator)),
            RPCMethod.paneInputEdgeSwipe.rawValue:
                .session(PaneMethods.edgeSwipe(paneCoordinator: paneCoordinator)),
            RPCMethod.paneInputEdgeTouch.rawValue:
                .session(PaneMethods.edgeTouch(paneCoordinator: paneCoordinator)),
            RPCMethod.paneInputLongPress.rawValue:
                .session(PaneMethods.longPress(paneCoordinator: paneCoordinator)),
            RPCMethod.paneInputKey.rawValue:
                .session(PaneMethods.key(paneCoordinator: paneCoordinator)),
            RPCMethod.paneInputButton.rawValue:
                .session(PaneMethods.button(paneCoordinator: paneCoordinator)),
            RPCMethod.paneInputRotate.rawValue:
                .session(PaneMethods.rotate(paneCoordinator: paneCoordinator)),
            RPCMethod.paneInputPinch.rawValue:
                .session(PaneMethods.pinch(paneCoordinator: paneCoordinator)),
            RPCMethod.paneInputMultitouch.rawValue:
                .session(PaneMethods.multitouch(paneCoordinator: paneCoordinator)),
            RPCMethod.paneInputText.rawValue:
                .session(PaneMethods.text(paneCoordinator: paneCoordinator)),
            RPCMethod.paneInputCrown.rawValue:
                .session(PaneMethods.crown(paneCoordinator: paneCoordinator)),
            RPCMethod.paneAXTree.rawValue:
                .session(PaneMethods.axTree(paneCoordinator: paneCoordinator)),
            RPCMethod.paneAXPoint.rawValue:
                .session(PaneMethods.axPoint(paneCoordinator: paneCoordinator)),
            RPCMethod.paneAXSweep.rawValue:
                .session(PaneMethods.axSweep(paneCoordinator: paneCoordinator)),

            // pane.location.*: `.validatedGUI`, so UDS can never reach
            // them (`MethodScope.validatedGUIReachable` is false for
            // `.uds` unconditionally). Location is a GUI affordance with
            // no CLI verb, since the CLI's "no simctl wrappers" reject
            // list names `location`. The scope makes "GUI only" a
            // dispatch fact rather than a convention, and keeps these out
            // of a UDS caller's advertised `allowedMethods`. See the
            // `RPCMethod` block comment.
            RPCMethod.paneLocationSet.rawValue:
                .validatedGUI(PaneMethods.locationSet(paneCoordinator: paneCoordinator)),
            RPCMethod.paneLocationState.rawValue:
                .validatedGUI(PaneMethods.locationState(paneCoordinator: paneCoordinator)),

            // Surface-lease notifications: one-way (no id, no response).
            // `pane.surfaceRelease` is the cumulative watermark ack, routed
            // to the pool; `pane.surfaceDrain` is subscription teardown
            // (not an ack), transport-intercepted on XPC and a no-op here
            // (UDS vends no surface lane). Session-scoped: only a connection
            // that authenticated to subscribe can meaningfully send them.
            RPCMethod.paneSurfaceRelease.rawValue:
                .session(PaneMethods.surfaceRelease(paneCoordinator: paneCoordinator)),
            RPCMethod.paneSurfaceDrain.rawValue:
                .session(PaneMethods.surfaceDrain()),

            // app.* back-channel: see `AppCommandMethods` and
            // `AppCommandCoordinator` for the publish/await dance
            // these handlers participate in.
            RPCMethod.appCommandResult.rawValue: .validatedGUI(
                AppCommandMethods.commandResult(coordinator: appCommandCoordinator)
            ),

            // tab.* / pane.* / window.*: each verb publishes an
            // AppCommand via the coordinator and awaits the GUI's
            // result. Session-scoped for verbs that target the
            // caller's tab/pane; daemon-wide for `windows.list`
            // (out-of-tab callers see only their own windows, but
            // the verb itself doesn't need session creds).
            //
            // Five carry `.automationTab` instead: `tab.open`,
            // `tab.select`, `tab.move`, `window.open`, and
            // `window.focus` create or rearrange workspace surfaces,
            // or change which one has focus. Selecting a tab can
            // replace the visible tab and move terminal focus; moving
            // one can shift other tabs' positions. Neither effect is
            // contained to the caller's own tab, so the gate is flat
            // and needs no target resolution.
            RPCMethod.tabOpen.rawValue: .automationTab(
                AppCommandMethods.publishVerb(
                    kind: .tabOpen,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.tabClose.rawValue: .session(
                AppCommandMethods.publishVerb(
                    kind: .tabClose,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.tabRename.rawValue: .session(
                AppCommandMethods.publishVerb(
                    kind: .tabRename,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.tabSelect.rawValue: .automationTab(
                AppCommandMethods.publishVerb(
                    kind: .tabSelect,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.tabInfo.rawValue: .session(
                AppCommandMethods.publishVerb(
                    kind: .tabInfo,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.tabMove.rawValue: .automationTab(
                AppCommandMethods.publishVerb(
                    kind: .tabMove,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.paneOpenTerminal.rawValue: .session(
                AppCommandMethods.publishVerb(
                    kind: .paneOpenTerminal,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.paneClose.rawValue: .session(
                AppCommandMethods.publishVerb(
                    kind: .paneClose,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.paneRename.rawValue: .session(
                AppCommandMethods.publishVerb(
                    kind: .paneRename,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.paneInfo.rawValue: .session(
                AppCommandMethods.publishVerb(
                    kind: .paneInfo,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.paneMove.rawValue: .session(
                AppCommandMethods.publishVerb(
                    kind: .paneMove,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.paneAttach.rawValue: .session(
                AppCommandMethods.publishVerb(
                    kind: .paneAttach,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.windowOpen.rawValue: .automationTab(
                AppCommandMethods.publishVerb(
                    kind: .windowOpen,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.windowClose.rawValue: .session(
                AppCommandMethods.publishVerb(
                    kind: .windowClose,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.windowFocus.rawValue: .automationTab(
                AppCommandMethods.publishVerb(
                    kind: .windowFocus,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.windowsList.rawValue: .daemonWide(
                AppCommandMethods.publishVerb(
                    kind: .windowsList,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),

            // Automation-only read/write verbs. The dispatcher's
            // scope check rejects callers without a live automation
            // grant before the handler runs; the GUI-side IntentDispatcher
            // resolves the ref and performs the read/write via
            // IntentActionDelegate.
            RPCMethod.tabSendInput.rawValue: .automationTab(
                AppCommandMethods.publishVerb(
                    kind: .tabSendInput,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            RPCMethod.tabCapture.rawValue: .automationTab(
                AppCommandMethods.publishVerb(
                    kind: .tabCapture,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            ),
            // Session-scoped: owner-only enforcement happens GUI-side
            // (IntentDispatcher's setTabProtected gate). Auth is still
            // required so an unauthenticated wire caller can't bypass
            // the GUI gate by guessing a TabRef.
            RPCMethod.tabSetProtected.rawValue: .session(
                AppCommandMethods.publishVerb(
                    kind: .tabSetProtected,
                    coordinator: appCommandCoordinator,
                    automationGrant: automationGrantStore
                )
            )
        ]
        let subscriptions: [String: MethodRegistry.ScopedSubscription] = [
            RPCMethod.paneSubscribe.rawValue:
                .session(PaneMethods.subscribe(paneCoordinator: paneCoordinator)),
            RPCMethod.daemonEvents.rawValue:
                .session(DaemonEventsMethods.subscribe(broker: eventBroker)),
            RPCMethod.appCommands.rawValue: .validatedGUI(
                AppCommandMethods.commandsSubscription(coordinator: appCommandCoordinator)
            )
        ]
        // Snapshot the (name, scope) table including capabilities
        // itself, so the capabilities handler's `methodsForRole`
        // closure correctly advertises self-callability. The
        // closure captures the snapshot by value; no back-reference
        // to the registry needed (the snapshot IS the source of
        // truth for the capability advertising).
        var scopes: [(name: String, scope: MethodScope)] =
            handlers.map { (name: $0.key, scope: $0.value.scope) }
        scopes += subscriptions.map {
            (name: $0.key, scope: $0.value.scope)
        }
        scopes.append(
            (
            name: RPCMethod.daemonCapabilities.rawValue,
            scope: .daemonWide
        )
            )
        let scopesSnapshot = scopes
        handlers[RPCMethod.daemonCapabilities.rawValue] = capabilities(
            automationGrantStore: automationGrantStore,
            methodsForRole: { role, automationTabReachable, validatedGUIReachable in
                methodsForRole(
                role,
                automationTabReachable: automationTabReachable,
                validatedGUIReachable: validatedGUIReachable,
                scopes: scopesSnapshot
            )
            }
        )
        return MethodRegistry(
            handlers: handlers,
            subscriptions: subscriptions,
            provenance: provenance,
            // Carry the SAME store the grant/revoke handlers and the
            // capabilities advertiser use, so both dispatchers' scope checks
            // read it off the registry: one ledger, no divergence.
            automationGrant: automationGrantStore
        )
    }
}
