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
        sessionId: "S-1",
        automationGrant: false,
        allowedMethods: ["daemon.ping", "pane.input.tap"],
        wireVersion: "0.1.0",
        linkagePolicyVersion: 1
    )
    let encoded = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder()
        .decode(DaemonCapabilitiesResponse.self, from: encoded)
    #expect(decoded.role == .agent)
    #expect(decoded.sessionId == "S-1")
    #expect(decoded.automationGrant == false)
    #expect(decoded.allowedMethods == ["daemon.ping", "pane.input.tap"])
    #expect(decoded.wireVersion == "0.1.0")
    #expect(decoded.linkagePolicyVersion == 1)
}

@Test
func responseRoundTripNoSession() throws {
    let response = DaemonCapabilitiesResponse(
        role: nil,
        sessionId: nil,
        automationGrant: false,
        allowedMethods: ["daemon.ping"],
        wireVersion: "0.1.0",
        linkagePolicyVersion: 1
    )
    let encoded = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder()
        .decode(DaemonCapabilitiesResponse.self, from: encoded)
    #expect(decoded.role == nil)
    #expect(decoded.sessionId == nil)
    #expect(decoded.allowedMethods == ["daemon.ping"])
}

@Test
func responseRoundTripAutomationRole() throws {
    let response = DaemonCapabilitiesResponse(
        role: .automation,
        sessionId: "S-2",
        automationGrant: true,
        allowedMethods: ["pane.sendInput", "pane.captureText"],
        wireVersion: "0.1.0",
        linkagePolicyVersion: 1
    )
    let encoded = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder()
        .decode(DaemonCapabilitiesResponse.self, from: encoded)
    #expect(decoded.role == .automation)
    #expect(decoded.automationGrant == true)
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

/// A reply from a daemon built before the grant fields existed still decodes,
/// and still answers the grant question. An `.automationTab` method appears in
/// `allowedMethods` exactly when the grant is live, so the derived value is the
/// same answer rather than a guess. Defaulting to false here would understate a
/// live grant during the update window instead.
@Test("derives the grant from allowedMethods when the flag is absent", arguments: [
    ([] as [String], false),
    (["daemon.ping"], false),
    (["daemon.ping", "pane.sendInput"], true)
])
func responseDerivesTheGrantWithoutTheFlag(allowed: [String], expected: Bool) throws {
    let methods = allowed.map { "\"\($0)\"" }.joined(separator: ",")
    let wire = "{\"allowedMethods\":[\(methods)],\"linkagePolicyVersion\":1,\"wireVersion\":\"0.6.0\"}"
    let decoded = try JSONDecoder()
        .decode(DaemonCapabilitiesResponse.self, from: Data(wire.utf8))

    #expect(decoded.automationGrant == expected)
    #expect(decoded.sessionId == nil)
    #expect(decoded.role == nil)
}

/// An explicit flag always wins, so a daemon that sends one is never
/// second-guessed by the fallback.
@Test("an explicit flag overrides the method list", arguments: [true, false])
func responsePrefersTheExplicitGrantFlag(flag: Bool) throws {
    let wire = "{\"allowedMethods\":[\"pane.sendInput\"],\"automationGrant\":\(flag),"
        + "\"linkagePolicyVersion\":1,\"wireVersion\":\"0.6.0\"}"
    let decoded = try JSONDecoder()
        .decode(DaemonCapabilitiesResponse.self, from: Data(wire.utf8))

    #expect(decoded.automationGrant == flag)
}
