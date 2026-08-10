// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// MethodRegistry's scope tagging + `methodsForRole(_:orchestratorTabReachable:validatedGUIReachable:)`.
// The registry is the source of truth for `daemon.capabilities`, so
// these tests pin the mapping exactly: nil gets daemonWide only; a
// session (agent OR orchestrator) gets daemonWide + session, and the
// `.orchestratorTab` methods are added purely from
// `orchestratorTabReachable` (the live grant), independent of role.
// `MethodScopeTransportTests` covers what makes it reachable.

private func passthrough() -> MethodRegistry.Handler {
    { _ in Data("{}".utf8) }
}

@Test
func methodsForRoleNilReturnsDaemonWideOnly() {
    let registry = MethodRegistry(
        handlers: [
            "a.public": .daemonWide(passthrough()),
            "b.session": .session(passthrough())
        ]
    )
    #expect(registry.methodsForRole(nil, orchestratorTabReachable: true, validatedGUIReachable: false) == ["a.public"])
}

@Test
func methodsForRoleAgentReturnsDaemonWideAndSession() {
    let registry = MethodRegistry(
        handlers: [
            "a.public": .daemonWide(passthrough()),
            "b.session": .session(passthrough())
        ]
    )
    let methods = registry.methodsForRole(
        .agent,
        orchestratorTabReachable: true,
        validatedGUIReachable: false
    )
    #expect(methods == ["a.public", "b.session"])
}

@Test
func methodsForRoleOrchestratorReturnsAllThreeScopes() {
    let registry = MethodRegistry(
        handlers: [
            "a.public": .daemonWide(passthrough()),
            "b.session": .session(passthrough()),
            "c.orchestrator": .orchestratorTab(passthrough())
        ]
    )
    let methods = registry.methodsForRole(.orchestrator, orchestratorTabReachable: true, validatedGUIReachable: false)
    #expect(methods == ["a.public", "b.session", "c.orchestrator"])
}

@Test
func methodsForRoleUngrantedExcludesOrchestrator() {
    // Authority is a grant, not a role. An UNGRANTED caller
    // (orchestratorTabReachable: false) never sees the orchestrator surface,
    // whatever its role.
    let registry = MethodRegistry(
        handlers: [
            "a.public": .daemonWide(passthrough()),
            "b.session": .session(passthrough()),
            "c.orchestrator": .orchestratorTab(passthrough())
        ]
    )
    #expect(
        registry.methodsForRole(.agent, orchestratorTabReachable: false, validatedGUIReachable: false)
            == ["a.public", "b.session"]
    )
    #expect(
        registry.methodsForRole(.orchestrator, orchestratorTabReachable: false, validatedGUIReachable: false)
            == ["a.public", "b.session"]
    )
}

@Test
func methodsForRoleGrantedAgentIncludesOrchestrator() {
    // A GRANTED agent (orchestratorTabReachable: true) sees the orchestrator
    // surface. A live orchestration grant gates orchestrator scope; role is
    // descriptive.
    let registry = MethodRegistry(
        handlers: [
            "a.public": .daemonWide(passthrough()),
            "b.session": .session(passthrough()),
            "c.orchestrator": .orchestratorTab(passthrough())
        ]
    )
    #expect(
        registry.methodsForRole(.agent, orchestratorTabReachable: true, validatedGUIReachable: false)
            == ["a.public", "b.session", "c.orchestrator"]
    )
}

@Test
func methodsForRoleSortsResults() {
    let registry = MethodRegistry(
        handlers: [
            "zoo.public": .daemonWide(passthrough()),
            "alpha.public": .daemonWide(passthrough())
        ]
    )
    let methods = registry.methodsForRole(nil, orchestratorTabReachable: true, validatedGUIReachable: false)
    #expect(methods == methods.sorted())
}

@Test
func methodsForRoleIncludesSubscriptions() {
    let registry = MethodRegistry(
        handlers: [
            "a.public": .daemonWide(passthrough())
        ],
        subscriptions: [
            "b.subscribe":
                .session { _, _ in MethodRegistry.SubscriptionResult(
                    initialResult: Data("{}".utf8),
                    events: AsyncStream { _ in },
                    onCancel: {}
                )
                }
        ]
    )
    let agentMethods = registry.methodsForRole(.agent, orchestratorTabReachable: true, validatedGUIReachable: false)
    #expect(agentMethods.contains("a.public"))
    #expect(agentMethods.contains("b.subscribe"))
}

@Test
func scopeOfReturnsRegisteredScope() {
    let registry = MethodRegistry(
        handlers: [
            "x.public": .daemonWide(passthrough()),
            "y.session": .session(passthrough())
        ]
    )
    #expect(registry.scope(of: "x.public") == .daemonWide)
    #expect(registry.scope(of: "y.session") == .session)
    #expect(registry.scope(of: "unknown") == nil)
}

// MARK: - Factory shapes

@Test
func orchestratorTabFactoryTagsHandlerWithOrchestratorTabScope() {
    // The handler stays trivial; dispatcher enforces the role
    // check. End-to-end behavior is tested in
    // `RPCConnectionAuthTests` via a real server+connection.
    let scoped = MethodRegistry.ScopedHandler.orchestratorTab { _ in
        Data("{}".utf8)
    }
    #expect(scoped.scope == .orchestratorTab)
}

@Test
func validatedGUIFactoryTagsHandlerWithValidatedGUIScope() {
    let scoped = MethodRegistry.ScopedHandler.validatedGUI { _ in
        Data("{}".utf8)
    }
    #expect(scoped.scope == .validatedGUI)
}

@Test
func sessionFactoryTagsHandlerWithSessionScope() {
    let scoped = MethodRegistry.ScopedHandler.session { _ in
        Data("{}".utf8)
    }
    #expect(scoped.scope == .session)
}

@Test
func daemonWideFactoryTagsHandlerWithDaemonWideScope() {
    let scoped = MethodRegistry.ScopedHandler.daemonWide { _ in
        Data("{}".utf8)
    }
    #expect(scoped.scope == .daemonWide)
}

@Test
func methodsForRoleOrchestratorUnreachableExcludesOrchestratorScope() {
    // `daemon.capabilities` promises the verbs the caller can
    // actually invoke. A connection that can't reach orchestrator
    // scope is refused those calls at dispatch even when the session
    // holds the role, so advertising them would promise calls that
    // always fail; the CLI filters `--help` off this list.
    let registry = MethodRegistry(
        handlers: [
            "a.public": .daemonWide(passthrough()),
            "b.session": .session(passthrough()),
            "c.orchestrator": .orchestratorTab(passthrough())
        ]
    )
    let methods = registry.methodsForRole(.orchestrator, orchestratorTabReachable: false, validatedGUIReachable: false)
    #expect(methods == ["a.public", "b.session"])
}
