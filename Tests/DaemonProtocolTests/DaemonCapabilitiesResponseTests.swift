// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// Wire shape for `daemon.capabilities`. The request carries NO body (the
// daemon derives authority from the provenance-checked connection, not payload
// creds) so only the RESPONSE has a wire shape to pin. It is the contract
// every CLI consumes to power role-aware `--help` filtering and
// `deviceterm doctor`'s permissions section, so its stability matters.

@Test
func responseRoundTripAgentRole() throws {
    let response = DaemonCapabilitiesResponse(
        role: .agent,
        allowedMethods: ["daemon.ping", "pane.input.tap"],
        wireVersion: "0.1.0",
        linkagePolicyVersion: 1
    )
    let encoded = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder()
        .decode(DaemonCapabilitiesResponse.self, from: encoded)
    #expect(decoded.role == .agent)
    #expect(decoded.allowedMethods == ["daemon.ping", "pane.input.tap"])
    #expect(decoded.wireVersion == "0.1.0")
    #expect(decoded.linkagePolicyVersion == 1)
}

@Test
func responseRoundTripNoSession() throws {
    let response = DaemonCapabilitiesResponse(
        role: nil,
        allowedMethods: ["daemon.ping"],
        wireVersion: "0.1.0",
        linkagePolicyVersion: 1
    )
    let encoded = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder()
        .decode(DaemonCapabilitiesResponse.self, from: encoded)
    #expect(decoded.role == nil)
    #expect(decoded.allowedMethods == ["daemon.ping"])
}

@Test
func responseRoundTripAutomationRole() throws {
    let response = DaemonCapabilitiesResponse(
        role: .automation,
        allowedMethods: ["tab.send-input", "tab.capture"],
        wireVersion: "0.1.0",
        linkagePolicyVersion: 1
    )
    let encoded = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder()
        .decode(DaemonCapabilitiesResponse.self, from: encoded)
    #expect(decoded.role == .automation)
}

@Test
func currentLinkagePolicyVersionIsOne() {
    // Locked at 1 for the current linkage model. Incrementing is
    // a deliberate decision that pairs with new on-the-wire linkage
    // semantics (new pane states, new `error.unlinked_pane` shapes).
    #expect(LinkagePolicy.currentVersion == 1)
}

@Test
func methodScopeRawValuesAreStable() {
    // `MethodScope` does NOT cross the wire: `daemon.capabilities`
    // carries `allowedMethods: [String]`, not scope tags. These
    // rawValues are an internal contract only; the test pins the case
    // set so a rename is a deliberate, visible diff rather than a
    // silent one.
    #expect(MethodScope.daemonWide.rawValue == "daemonWide")
    #expect(MethodScope.session.rawValue == "session")
    #expect(MethodScope.automationTab.rawValue == "automationTab")
    #expect(MethodScope.validatedGUI.rawValue == "validatedGUI")
    #expect(MethodScope.allCases.count == 4)
}
