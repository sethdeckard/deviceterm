// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// MethodRegistry's scope tagging + `methodsForRole(_:automationTabReachable:validatedGUIReachable:)`.
// The registry is the source of truth for `daemon.capabilities`, so
// these tests pin the mapping exactly: nil gets daemonWide only; a
// session (agent OR automation) gets daemonWide + session, and the
// `.automationTab` methods are added purely from
// `automationTabReachable` (the live grant), independent of role.
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
    #expect(registry.methodsForRole(nil, automationTabReachable: true, validatedGUIReachable: false) == ["a.public"])
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
        automationTabReachable: true,
        validatedGUIReachable: false
    )
    #expect(methods == ["a.public", "b.session"])
}

@Test
func methodsForRoleAutomationReturnsAllThreeScopes() {
    let registry = MethodRegistry(
        handlers: [
            "a.public": .daemonWide(passthrough()),
            "b.session": .session(passthrough()),
            "c.automation": .automationTab(passthrough())
        ]
    )
    let methods = registry.methodsForRole(.automation, automationTabReachable: true, validatedGUIReachable: false)
    #expect(methods == ["a.public", "b.session", "c.automation"])
}

@Test
func methodsForRoleUngrantedExcludesAutomation() {
    // Authority is a grant, not a role. An UNGRANTED caller
    // (automationTabReachable: false) never sees the automation surface,
    // whatever its role.
    let registry = MethodRegistry(
        handlers: [
            "a.public": .daemonWide(passthrough()),
            "b.session": .session(passthrough()),
            "c.automation": .automationTab(passthrough())
        ]
    )
    #expect(
        registry.methodsForRole(.agent, automationTabReachable: false, validatedGUIReachable: false)
            == ["a.public", "b.session"]
    )
    #expect(
        registry.methodsForRole(.automation, automationTabReachable: false, validatedGUIReachable: false)
            == ["a.public", "b.session"]
    )
}

@Test
func methodsForRoleGrantedAgentIncludesAutomation() {
    // A GRANTED agent (automationTabReachable: true) sees the automation
    // surface. A live automation grant gates automation scope; role is
    // descriptive.
    let registry = MethodRegistry(
        handlers: [
            "a.public": .daemonWide(passthrough()),
            "b.session": .session(passthrough()),
            "c.automation": .automationTab(passthrough())
        ]
    )
    #expect(
        registry.methodsForRole(.agent, automationTabReachable: true, validatedGUIReachable: false)
            == ["a.public", "b.session", "c.automation"]
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
    let methods = registry.methodsForRole(nil, automationTabReachable: true, validatedGUIReachable: false)
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
    let agentMethods = registry.methodsForRole(.agent, automationTabReachable: true, validatedGUIReachable: false)
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
func automationTabFactoryTagsHandlerWithAutomationTabScope() {
    // The handler stays trivial; dispatcher enforces the role
    // check. End-to-end behavior is tested in
    // `RPCConnectionAuthTests` via a real server+connection.
    let scoped = MethodRegistry.ScopedHandler.automationTab { _ in
        Data("{}".utf8)
    }
    #expect(scoped.scope == .automationTab)
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
func methodsForRoleAutomationUnreachableExcludesAutomationScope() {
    // `daemon.capabilities` promises the verbs the caller can
    // actually invoke. A connection that can't reach automation
    // scope is refused those calls at dispatch even when the session
    // holds the role, so advertising them would promise calls that
    // always fail; the CLI filters `--help` off this list.
    let registry = MethodRegistry(
        handlers: [
            "a.public": .daemonWide(passthrough()),
            "b.session": .session(passthrough()),
            "c.automation": .automationTab(passthrough())
        ]
    )
    let methods = registry.methodsForRole(.automation, automationTabReachable: false, validatedGUIReachable: false)
    #expect(methods == ["a.public", "b.session"])
}
