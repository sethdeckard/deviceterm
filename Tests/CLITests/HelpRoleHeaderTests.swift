// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// `HelpText.render(role:)` + `roleHeader(role:)`. The header line is the
// visible API contract: it reports the descriptive role the daemon
// advertised for the caller. It does not describe authorization, which
// follows the session's live orchestration grant and its transport. It is
// the only role-varying part of the output; the command list itself is
// never filtered, so a listed command can still be refused.

@Test
func headerForNoSessionMatchesOutOfTabContext() {
    let header = HelpText.roleHeader(role: nil)
    #expect(header == "Command reference (no deviceterm session)\n")
}

@Test
func headerForAgentRoleIdentifiesIt() {
    let header = HelpText.roleHeader(role: .agent)
    #expect(header == "Command reference (session role: agent)\n")
}

@Test
func headerForOrchestratorRoleIdentifiesIt() {
    let header = HelpText.roleHeader(role: .orchestrator)
    #expect(header.contains("role: orchestrator"))
}

@Test
func renderShowsTheCompactCommandList() {
    // render(role:) prepends the header + a blank line to the command
    // list. It is the list, not the whole reference: a caller who wants
    // one command in full asks for it by name.
    let rendered = HelpText.render(role: .agent)
    #expect(rendered.contains("Command reference (session role: agent)"))
    #expect(rendered.contains("deviceterm help <command>"))
    #expect(rendered.hasSuffix("\n"))
    // A command's body belongs on its own page, not here.
    #expect(!rendered.contains("digitalCrownRotation"))
}

@Test
func renderPlacesHeaderBeforeBanner() {
    // The header must come first: an agent piping `deviceterm help`
    // through `head -1` should see the role line, not the banner. This
    // is also the tripwire if the banner ever leaves the command list.
    let rendered = HelpText.render(role: .agent)
    let headerRange = rendered.range(of: "Command reference")
    let bannerRange = rendered.range(of: "deviceterm is a macOS terminal")
    if let header = headerRange, let banner = bannerRange {
        #expect(header.lowerBound < banner.lowerBound)
    } else {
        Issue.record("render must contain both header and banner")
    }
}

@Test
func topicPagesCarryNoRoleHeader() {
    // A command page answers "how does this work?", not "what may I
    // run?". Keeping the role off it is also what lets `deviceterm help
    // crown` skip the daemon round-trip entirely.
    for name in HelpCatalog.topicNames {
        let page = HelpText.page(forTopic: name) ?? ""
        #expect(
            !page.contains("Command reference"),
            "role header leaked onto the \(name) page"
            )
    }
}
