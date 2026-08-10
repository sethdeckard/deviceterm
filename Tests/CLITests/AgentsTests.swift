// SPDX-License-Identifier: GPL-3.0-or-later

@testable import DeviceTermCLI
import Foundation
import Testing

// `deviceterm agents` parsing + content invariants.
//
// Parser side: `deviceterm agents` resolves to .agents; extra trailing
// args are tolerated (the guide is one document); `--json` doesn't
// switch the output (the guide is text).
//
// Content side: every load-bearing section and every practical
// gotcha the guide is supposed to carry is pinned.
// Future edits that drop a section will fail the test before they
// merge.

// MARK: - Parser

@Test
func parseAgentsVerbResolvesToAgents() {
    #expect(CLICommands.parse(["deviceterm", "agents"]) == .agents)
}

@Test
func parseAgentsTolerateTrailingArgs() {
    // The guide is one document; trailing tokens don't change it.
    // Same forgiveness as `--help <anything>`.
    #expect(CLICommands.parse(["deviceterm", "agents", "crown"]) == .agents)
    #expect(CLICommands.parse(["deviceterm", "agents", "tap", "0.5", "0.5"]) == .agents)
}

@Test
func parseAgentsStripsJSONFlag() {
    // The CLI strips --json globally before dispatch. The guide is
    // text either way, since there is no JSON form of the guide, so the
    // strip exists only to keep the verb from being shadowed.
    #expect(CLICommands.parse(["deviceterm", "agents", "--json"]) == .agents)
}

@Test
func parseTextTreatsAgentsAsLiteral() {
    // Regression guard for the text-literal pattern: the `agents`
    // verb fires only in the verb position. Downstream text input
    // that happens to contain "agents" stays literal.
    #expect(
        CLICommands.parse(["deviceterm", "text", "agents"])
        == .text(pane: nil, text: "agents")
        )
}

// MARK: - Critical sections (load-bearing)

@Test
func agentsDocumentationOpensWithBannerAndScope() {
    #expect(AgentsText.documentation.hasPrefix("deviceterm agents"))
    // The intro must distinguish the agents surface from --help.
    #expect(AgentsText.documentation.contains("--help"))
}

@Test
func agentsDocumentationCarriesGettingASimSection() {
    // The bootstrap-confusion case: an agent without context can
    // get stuck with no path to *attach* a sim. This section is
    // the load-bearing recovery; it must surface every time.
    #expect(AgentsText.documentation.contains("GETTING A SIM INTO YOUR TAB"))
    #expect(AgentsText.documentation.contains("xcrun simctl boot"))
    #expect(AgentsText.documentation.contains("env | grep DEVICETERM"))
    #expect(AgentsText.documentation.contains("which xcrun"))
    #expect(AgentsText.documentation.contains("panes list"))
}

@Test
func agentsDocumentationCarriesTriageSectionForCrown() {
    // Pin every checklist item the crown triage called out by name.
    let documentation = AgentsText.documentation
    #expect(documentation.contains("single-shot"))
    #expect(documentation.contains("digitalCrownRotation"))
    #expect(documentation.contains("coalescing floor"))
    #expect(documentation.contains("milliseconds, not seconds"))
    #expect(documentation.contains("silently ignored at the daemon"))
}

@Test
func agentsDocumentationCarriesTriageSectionForSwipe() {
    // Sub-frame collapse: the agent must know dispatched=tap
    // means their --duration was below 32ms.
    let documentation = AgentsText.documentation
    #expect(documentation.contains("dispatched=tap"))
    #expect(documentation.contains("one-frame floor"))
}

@Test
func agentsDocumentationCarriesAXTreeWatchOSWorkaround() {
    // `ax sweep` is the watchOS workaround for empty
    // `accessibilityChildren` walks.
    let documentation = AgentsText.documentation
    #expect(documentation.contains("ax sweep"))
    #expect(documentation.contains("accessibilityChildren"))
    #expect(documentation.contains("objectAtPoint:"))
}

@Test
func agentsDocumentationCarriesPermissionsAndLinkageSection() {
    // The guide carries a Permissions and linkage section covering
    // what the cap authorizes, what the roles are, and where the
    // boundary sits.
    let documentation = AgentsText.documentation
    #expect(documentation.contains("PERMISSIONS AND LINKAGE"))
    #expect(documentation.contains("The trust boundary is the terminal session"))
    #expect(documentation.contains("Roles"))
    // The three human-only authority axes. An agent hitting one
    // needs to know the GUI is the path rather than retrying with
    // different arguments. They are not equally strong (role
    // escalation and privacy are refused by the daemon, linkage
    // only by the CLI verb) and the guide says so; this pins that
    // all three stay documented, not that they share a mechanism.
    #expect(documentation.contains("Linkage-mutation"))
    #expect(documentation.contains("Role escalation"))
    #expect(documentation.contains("Privacy-mutation"))
    // No roadmap framing: the guide states what holds now.
    #expect(!documentation.contains("Coming soon"))
}

@Test
func agentsDocumentationCarriesWorkflowRecipes() {
    let documentation = AgentsText.documentation
    #expect(documentation.contains("WORKFLOW RECIPES"))
    // At least one recipe per major verb class.
    #expect(documentation.contains("deviceterm tap"))
    #expect(documentation.contains("deviceterm swipe"))
    #expect(documentation.contains("deviceterm crown"))
    #expect(documentation.contains("deviceterm ax tree"))
    #expect(documentation.contains("deviceterm text"))
    #expect(documentation.contains("--pane"))
}

@Test
func agentsDocumentationCarriesIntegrationTips() {
    let documentation = AgentsText.documentation
    #expect(documentation.contains("INTEGRATION TIPS"))
    // Env vars + --json + identifier model: the three surfaces
    // an integrating agent needs to know.
    #expect(documentation.contains("DEVICETERM_SESSION"))
    #expect(documentation.contains("DEVICETERM_DAEMON_SOCK"))
    #expect(documentation.contains("--json"))
    #expect(documentation.contains("shortId"))
}

@Test
func agentsDocumentationScopesJSONClaimToDataCommands() {
    // Regression guard: the INTEGRATION TIPS section must not claim "every command"
    // supports --json when documentation commands (--help,
    // agents) are deliberately text-only. The carve-out has to
    // be explicit so a future copy-edit can't silently re-broaden
    // the promise into a contradiction with runtime behavior.
    let documentation = AgentsText.documentation
    #expect(documentation.contains("Data commands"))
    #expect(documentation.contains("text-only"))
}

@Test
func agentsDocumentationCarriesCatEPhilosophyCalloutCMissingFromCLI() {
    // The Cat E "what's NOT in the deviceterm CLI by design" gate.
    // simctl wrappers, MCP layer, recipe library are all
    // deliberately rejected. The guide has to say so so agents
    // don't file feature requests for them.
    let documentation = AgentsText.documentation
    #expect(documentation.contains("simctl"))
    #expect(documentation.contains("by design"))
}

@Test
func agentsDocumentationLineWidthFitsInEightyCols() {
    // Same readability target as HelpText: render cleanly in any
    // 80-col terminal.
    for (index, line) in AgentsText.documentation.split(separator: "\n").enumerated() {
        #expect(
            line.count <= 80,
            "agents line \(index + 1) is \(line.count) chars: \(line)"
            )
    }
}
