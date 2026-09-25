// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Darwin
import Foundation
import Testing

@testable import DeviceTermCLI

@Test
func surfaceObservationPreservesEventsCoalescedWithAcknowledgement() throws {
    var sockets: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    defer { UDSClientSocket.close(sockets[1]) }
    _ = fcntl(sockets[0], F_SETFL, O_NONBLOCK)
    let observation = UDSSurfaceObservation(fd: sockets[0], paneId: "PANE")
    defer { observation.close() }
    let ack = RPCEnvelope(
        id: 1,
        type: .response,
        method: nil,
        body: .result(try JSONEncoder().encode(PaneSubscribeAck(success: true, subscriptionToken: nil)))
    )
    let first = try surfaceEventFrame(sequence: 4)
    let second = try surfaceEventFrame(sequence: 5)
    try UDSClientSocket.writeAll(
        fd: sockets[1], data: RPCFraming.encode(try ack.encode()) + first + second.prefix(6)
    )
    try observation.readAcknowledgement(deadline: Date().addingTimeInterval(1))
    #expect(try observation.latestSequence() == 4)
    try UDSClientSocket.writeAll(fd: sockets[1], data: Data(second.dropFirst(6)))
    #expect(try observation.latestSequence() == 5)
    observation.close()
    #expect(try UDSClientSocket.readAvailable(fd: sockets[1]) == nil)
}

@Test
func surfaceObservationReportsClosedPeer() throws {
    var sockets: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    _ = fcntl(sockets[0], F_SETFL, O_NONBLOCK)
    let observation = UDSSurfaceObservation(fd: sockets[0], paneId: "PANE")
    defer { observation.close() }
    UDSClientSocket.close(sockets[1])
    #expect(throws: CLIError.self) { try observation.latestSequence() }
}

private func surfaceEventFrame(sequence: UInt64) throws -> Data {
    let envelope = RPCEnvelope(
        id: 1,
        type: .event,
        method: PaneEventName.surfaceChanged.rawValue,
        body: .params(try JSONEncoder().encode(SurfaceChangedEvent(paneId: "PANE", sequence: sequence)))
    )
    return RPCFraming.encode(try envelope.encode())
}
