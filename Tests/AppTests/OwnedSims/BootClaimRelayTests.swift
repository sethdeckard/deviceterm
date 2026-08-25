// SPDX-License-Identifier: GPL-3.0-or-later
//
// BootClaimRelayTests: the terminal-local relay binds authority to kernel
// provenance, caps frames, and creates a mode-0600 endpoint.

@testable import App
import DaemonProtocol
import Foundation
import TerminalProvenance
import Testing

private let relaySession = "33333333-3333-3333-3333-333333333333"
private let relayUDID = "44444444-4444-4444-4444-444444444444"

@MainActor
private final class RelayCapture {
    var claims: [BootClaimEvidence] = []

    func record(_ claim: BootClaimEvidence) {
        claims.append(claim)
    }
}

private func relayFacts() -> TerminalAnchorFacts {
    TerminalAnchorFacts(
        terminalSessionId: 4_321,
        sessionLeaderStartTime: 99,
        controllingTTYDevice: 77
    )
}

private func relaySnapshot(matches facts: TerminalAnchorFacts) -> ProvenanceSnapshot {
    ProvenanceSnapshot(
        peer: PeerProcessIdentity(
            pid: getpid(),
            pidVersion: 1,
            euid: geteuid(),
            posixSessionId: facts.terminalSessionId,
            controllingTTYDev: facts.controllingTTYDevice,
            posixSessionLeaderStartTime: facts.sessionLeaderStartTime
        ),
        ancestors: []
    )
}

private func relayClaim() -> BootClaimEvidence {
    BootClaimEvidence(
        attemptId: UUID().uuidString,
        udid: relayUDID,
        source: .shim,
        observedState: .booting
    )
}

private func sendRelayPayload(_ payload: Data, to path: String) throws -> BootClaimRelayAck {
    let fd = try UDSClientSocket.connect(to: path)
    defer { UDSClientSocket.close(fd) }
    try UDSClientSocket.writeAll(fd: fd, data: RPCFraming.encode(payload))
    let deadline = Date(timeIntervalSinceNow: 2)
    var received = Data()
    while Date() < deadline {
        if let frame = try RPCFraming.decodeNext(from: received) {
            return try JSONDecoder().decode(BootClaimRelayAck.self, from: frame.payload)
        }
        if let chunk = try UDSClientSocket.readAvailable(fd: fd) {
            received.append(chunk)
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw CocoaError(.fileReadUnknown)
}

@Test
@MainActor
func relaySocketIsOwnerOnly() throws {
    let facts = relayFacts()
    let capture = RelayCapture()
    let relay = BootClaimRelay(
        sessionId: relaySession,
        handler: { _, claim, _ in capture.record(claim) },
        resolveProvenance: { _ in relaySnapshot(matches: facts) }
    )
    try relay.start()
    defer { relay.stop() }

    let attributes = try FileManager.default.attributesOfItem(atPath: relay.socketPath)
    let mode = try #require(attributes[.posixPermissions] as? NSNumber).intValue
    #expect(mode & 0o777 == 0o600)
}

@Test
@MainActor
func relayAnswersNotReadyUntilTerminalIsBound() throws {
    let facts = relayFacts()
    let capture = RelayCapture()
    let relay = BootClaimRelay(
        sessionId: relaySession,
        handler: { _, claim, _ in capture.record(claim) },
        resolveProvenance: { _ in relaySnapshot(matches: facts) }
    )
    try relay.start()
    defer { relay.stop() }

    let ack = try sendRelayPayload(JSONEncoder().encode(relayClaim()), to: relay.socketPath)
    #expect(ack.status == .notReady)
    #expect(capture.claims.isEmpty)
}

@Test
@MainActor
func relayAcceptsMatchingTerminalDescendant() async throws {
    let facts = relayFacts()
    let capture = RelayCapture()
    let relay = BootClaimRelay(
        sessionId: relaySession,
        handler: { _, claim, _ in capture.record(claim) },
        resolveProvenance: { _ in relaySnapshot(matches: facts) }
    )
    try relay.start()
    relay.bindForTesting(facts)
    defer { relay.stop() }

    let claim = relayClaim()
    let ack = try sendRelayPayload(JSONEncoder().encode(claim), to: relay.socketPath)
    #expect(ack.status == .accepted)
    try? await Task.sleep(nanoseconds: 30_000_000)
    #expect(capture.claims == [claim])
}

@Test
@MainActor
func relayRejectsOversizedFrame() throws {
    let facts = relayFacts()
    let capture = RelayCapture()
    let relay = BootClaimRelay(
        sessionId: relaySession,
        handler: { _, claim, _ in capture.record(claim) },
        resolveProvenance: { _ in relaySnapshot(matches: facts) }
    )
    try relay.start()
    relay.bindForTesting(facts)
    defer { relay.stop() }

    let ack = try sendRelayPayload(
        Data(repeating: 0x61, count: BootClaimRelay.maximumFrameBytes + 1),
        to: relay.socketPath
    )
    #expect(ack.status == .rejected)
    #expect(capture.claims.isEmpty)
}
