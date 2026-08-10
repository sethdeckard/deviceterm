// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// `SessionRole` raw values + Codable round-trip. Two values,
// immutable for the session's lifetime; the rawValue is the wire
// contract, so renaming a case is a wire-breaking change that must
// bump `DaemonProtocolInfo.wireVersion`.

@Test
func sessionRoleAgentRawValue() {
    #expect(SessionRole.agent.rawValue == "agent")
}

@Test
func sessionRoleOrchestratorRawValue() {
    #expect(SessionRole.orchestrator.rawValue == "orchestrator")
}

@Test
func sessionRoleCaseCount() {
    // Two roles, no more. The role enum is deliberately bounded to
    // agent/orchestrator: "human" is a GUI-only escalation primitive
    // rather than a role a session can hold, so it has no case here.
    // Adding a third case is a real semantic change to the trust
    // model, not a mechanical extension, so this guard exists to make
    // that decision explicit rather than incidental.
    #expect(SessionRole.allCases.count == 2)
}

@Test
func sessionRoleCodableRoundTripAgent() throws {
    let encoded = try JSONEncoder().encode(SessionRole.agent)
    #expect(String(data: encoded, encoding: .utf8) == "\"agent\"")
    let decoded = try JSONDecoder().decode(SessionRole.self, from: encoded)
    #expect(decoded == .agent)
}

@Test
func sessionRoleCodableRoundTripOrchestrator() throws {
    let encoded = try JSONEncoder().encode(SessionRole.orchestrator)
    #expect(String(data: encoded, encoding: .utf8) == "\"orchestrator\"")
    let decoded = try JSONDecoder().decode(SessionRole.self, from: encoded)
    #expect(decoded == .orchestrator)
}

@Test
func sessionRoleRejectsUnknownString() throws {
    let payload = Data("\"admin\"".utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SessionRole.self, from: payload)
    }
}
