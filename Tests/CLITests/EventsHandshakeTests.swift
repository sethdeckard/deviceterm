// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// `deviceterm events` frame handling. The subscription ack and the first event
// can arrive in a single read (coalesced on the wire); the streaming loop must
// decode both from the shared buffer, not strand the event waiting for more
// bytes. `drainEventFrames` is the pure classifier that behavior rests on.

private func framed(_ envelope: RPCEnvelope) throws -> Data {
    RPCFraming.encode(try envelope.encode())
}

@Test
func drainEventFramesYieldsAckThenCoalescedEvent() throws {
    let ack = RPCEnvelope(id: 1, type: .response, method: nil, body: .empty)
    let eventJSON = Data(#"{"kind":"device.booted"}"#.utf8)
    let event = RPCEnvelope(id: 1, type: .event, method: "device.booted", body: .params(eventJSON))

    // Both frames in ONE buffer, as if read together.
    var buffer = try framed(ack) + framed(event)
    let outcomes = drainEventFrames(from: &buffer)

    #expect(outcomes == [.subscriptionAck, .event(eventJSON)])
    #expect(buffer.isEmpty)  // both consumed, no tail stranded
}

@Test
func drainEventFramesLeavesAPartialTailBuffered() throws {
    let event = RPCEnvelope(id: 1, type: .event, method: "x", body: .params(Data("{}".utf8)))
    var buffer = try framed(event)
    // Truncate mid-frame. A partial frame must NOT be consumed or misdecoded.
    let full = buffer
    buffer.removeLast(2)
    #expect(drainEventFrames(from: &buffer).isEmpty)
    #expect(buffer.count == full.count - 2)  // partial tail preserved for the next read
}

@Test
func drainEventFramesClassifiesErrors() throws {
    let outOfTab = RPCEnvelope(
        id: 1,
        type: .response,
        method: nil,
        body: .error(RPCError(code: -32_001, message: "nope"))
    )
    let other = RPCEnvelope(
        id: 1,
        type: .response,
        method: nil,
        body: .error(RPCError(code: -32_050, message: "boom"))
    )
    var buffer = try framed(outOfTab) + framed(other)
    let outcomes = drainEventFrames(from: &buffer)
    #expect(outcomes == [.unauthorizedSession, .daemonError(code: -32_050, message: "boom")])
}
