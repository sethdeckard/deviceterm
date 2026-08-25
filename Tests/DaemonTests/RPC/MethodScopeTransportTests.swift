// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// `MethodScope.automationTabReachable` / `validatedGUIReachable`:
// the predicates both the dispatcher's scope check and
// `daemon.capabilities` consult. Advertising and enforcement
// disagreeing is the bug this guards: a caller told it may run
// `tab.capture` and then refused is worse than never being offered it.

@Test
func automationTabUnreachableWithoutAGrant() {
    // Authority is a live grant, not a role. With no grant, unreachable on
    // every transport regardless of the validated-GUI verdict.
    for transport in [DispatchPeerContext.Transport.uds, .xpc] {
        #expect(
            !MethodScope.automationTabReachable(
                hasGrant: false,
                transport: transport,
                validatedGUI: true
            )
        )
    }
}

@Test
func automationTabReachableOverUDSWithGrant() {
    // A granted UDS session reaches the automation surface: it authenticated
    // via cap + kernel terminal-process provenance, and the validated GUI
    // minted the grant. No audit token is involved over UDS, so the
    // validated-GUI verdict is irrelevant to the UDS decision, reachable
    // either way, purely on the grant.
    #expect(
        MethodScope.automationTabReachable(hasGrant: true, transport: .uds, validatedGUI: false)
    )
    #expect(
        MethodScope.automationTabReachable(hasGrant: true, transport: .uds, validatedGUI: true)
    )
    // Still refused over UDS WITHOUT a grant (covered by
    // `automationTabUnreachableWithoutAGrant`, restated here for the axis).
    #expect(
        !MethodScope.automationTabReachable(hasGrant: false, transport: .uds, validatedGUI: false)
    )
}

@Test
func automationTabReachableOverValidatedXPCWithGrant() {
    // Granted + validated XPC → reachable; an unvalidated XPC peer fails
    // closed even with a grant.
    #expect(
        MethodScope.automationTabReachable(hasGrant: true, transport: .xpc, validatedGUI: true)
    )
    #expect(
        !MethodScope.automationTabReachable(hasGrant: true, transport: .xpc, validatedGUI: false)
    )
}

@Test
func validatedGUIReachableOnlyOverValidatedXPC() {
    // Orthogonal to role and session, the only thing that matters is
    // an XPC peer that validated against the daemon's signature.
    #expect(
        MethodScope.validatedGUIReachable(transport: .xpc, validatedGUI: true)
    )
    #expect(
        !MethodScope.validatedGUIReachable(transport: .xpc, validatedGUI: false)
    )
    // UDS never validates, so it can never reach `.validatedGUI` even
    // if a refactor mis-sets the bool.
    #expect(
        !MethodScope.validatedGUIReachable(transport: .uds, validatedGUI: true)
    )
    #expect(
        !MethodScope.validatedGUIReachable(transport: .uds, validatedGUI: false)
    )
}

@Test
func allowedScopesTrackGrantNotRole() {
    // A GRANTED agent gets the automation surface. A live automation
    // grant gates automation scope; role is descriptive.
    #expect(
        MethodScope.allowedFor(
            role: .agent,
            automationTabReachable: true,
            validatedGUIReachable: false
        ) == [.daemonWide, .session, .automationTab]
    )
    // An UNGRANTED automation does not; it degrades to the agent set.
    #expect(
        MethodScope.allowedFor(
            role: .automation,
            automationTabReachable: false,
            validatedGUIReachable: false
        ) == [.daemonWide, .session]
    )
    // A granted automation gets it too (same as a granted agent).
    #expect(
        MethodScope.allowedFor(
            role: .automation,
            automationTabReachable: true,
            validatedGUIReachable: false
        ) == [.daemonWide, .session, .automationTab]
    )
    // No session (nil role) never gets `.automationTab`, since a grant
    // requires a session.
    #expect(
        MethodScope.allowedFor(
            role: nil,
            automationTabReachable: true,
            validatedGUIReachable: false
        ) == [.daemonWide]
    )
}

@Test
func validatedGUIScopeIsInsertedOrthogonallyToRole() {
    // `.validatedGUI` is added independently of role: a validated GUI
    // peer with no session still gets it, and a role-bearing session
    // gains it on top of its role set.
    #expect(
        MethodScope.allowedFor(
            role: nil,
            automationTabReachable: false,
            validatedGUIReachable: true
        ) == [.daemonWide, .validatedGUI]
    )
    #expect(
        MethodScope.allowedFor(
            role: .automation,
            automationTabReachable: true,
            validatedGUIReachable: true
        ) == [.daemonWide, .session, .automationTab, .validatedGUI]
    )
}
