// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// The cross-tab permission matrix, one
/// row per case, against the pure decision type.
///
/// The dispatcher tests cover the wiring (which verb carries which
/// requirement, and that the refusal reaches the caller). These cover the
/// rule itself, including the two cases the rule turns on: a sibling
/// terminal in the caller's own tab, and a caller with no session at all.
struct WorkspaceAuthorityDecisionTests {
    private func decide(
        origin: IntentOrigin,
        _ requirement: WorkspaceAuthorityRequirement,
        owns: Bool,
        terminals: Int = 1
    ) -> WorkspaceAuthorityDecision {
        WorkspaceAuthorityDecision.decide(
            origin: origin,
            requirement: requirement,
            target: WorkspaceAuthorityTarget(
                callerOwnsIt: owns,
                terminalCount: terminals
            )
        )
    }

    private func ungranted(_ session: String? = "S-A") -> IntentOrigin {
        .external(sessionID: session, hasAutomationGrant: false)
    }

    private func granted(_ session: String? = "S-A") -> IntentOrigin {
        .external(sessionID: session, hasAutomationGrant: true)
    }

    // MARK: - Ownership requirement (rename, pane open, pane close)

    @Test
    func ownershipPassesOnYourOwnTabWithoutAGrant() {
        #expect(decide(origin: ungranted(), .ownership, owns: true) == .allowed)
    }

    @Test
    func ownershipNeedsAGrantOnSomebodyElsesTab() {
        #expect(
            decide(origin: ungranted(), .ownership, owns: false)
                == .requiresAutomation
        )
    }

    @Test
    func aGrantReachesAForeignTab() {
        #expect(decide(origin: granted(), .ownership, owns: false) == .allowed)
    }

    // MARK: - Sole-terminal requirement (tab close, window close)

    @Test
    func closingYourOwnSingleTerminalTabNeedsNoGrant() {
        // Your own tab, your only shell in it: this is `exit` by another
        // name, so it stays free.
        #expect(
            decide(origin: ungranted(), .soleTerminal, owns: true, terminals: 1)
                == .allowed
        )
    }

    @Test
    func closingASplitTabNeedsAGrantEvenWhenYouOwnATerminal() {
        // The line the whole rule turns on. The trust unit is the
        // session, and a split tab holds several, so closing it ends
        // sibling sessions' work: the same cross-session destruction as
        // closing a foreign tab, reached by a different route.
        #expect(
            decide(origin: ungranted(), .soleTerminal, owns: true, terminals: 2)
                == .requiresAutomation
        )
    }

    @Test
    func aGrantClosesASplitTab() {
        #expect(
            decide(origin: granted(), .soleTerminal, owns: true, terminals: 2)
                == .allowed
        )
    }

    @Test
    func closingAForeignTabNeedsAGrantEvenWhenItHoldsOneTerminal() {
        #expect(
            decide(origin: ungranted(), .soleTerminal, owns: false, terminals: 1)
                == .requiresAutomation
        )
    }

    // MARK: - Origins

    @Test("a nil-session caller owns nothing and can hold no grant", arguments: [
        WorkspaceAuthorityRequirement.ownership,
        WorkspaceAuthorityRequirement.soleTerminal
    ])
    func nilSessionIsRefusedEverywhere(requirement: WorkspaceAuthorityRequirement) {
        // No special case in the rule: a caller with no session owns
        // nothing, so every predicate is false and it needs a grant it
        // has no way to hold. Fail closed by construction.
        #expect(
            decide(origin: ungranted(nil), requirement, owns: false)
                == .requiresAutomation
        )
    }

    @Test("the human at the keyboard is never gated", arguments: [
        WorkspaceAuthorityRequirement.ownership,
        WorkspaceAuthorityRequirement.soleTerminal
    ])
    func inProcessAlwaysPasses(requirement: WorkspaceAuthorityRequirement) {
        // The resolver has already refused anything the human can't see,
        // and the workspace is theirs. Closing a split tab from the tab
        // strip must not ask for a grant.
        #expect(
            decide(origin: .inProcess, requirement, owns: false, terminals: 3)
                == .allowed
        )
    }
}
