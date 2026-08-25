// SPDX-License-Identifier: GPL-3.0-or-later
//
// `pane.input.rotate` carries its two forms as mutually exclusive
// optional fields. These pin that the target initializer sets exactly
// one and omits the other (a nil Optional encodes as an absent key, not
// a JSON null), and that a request round-trips back to the same target.
// The daemon's rejection of both-set and neither-set lives with the
// handler, since that is where the wire's looser shape is enforced.

import DaemonProtocol
import Foundation
import Testing

private func encoded(_ params: RotateParams) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(params)
    return try #require(String(bytes: data, encoding: .utf8))
}

@Test
func absoluteRotateEncodesOrientationOnly() throws {
    let json = try encoded(RotateParams(paneId: "p1", target: .absolute(.landscapeLeft)))
    #expect(json == #"{"orientation":"landscapeLeft","paneId":"p1"}"#)
}

@Test
func relativeRotateEncodesDirectionOnly() throws {
    let json = try encoded(RotateParams(paneId: "p1", target: .relative(.left)))
    #expect(json == #"{"direction":"left","paneId":"p1"}"#)
}

@Test(
    "every target round-trips through the wire shape",
    arguments: Orientation.allCases.map { RotationTarget.absolute($0) }
        + RotationDirection.allCases.map { RotationTarget.relative($0) }
)
func targetRoundTripsThroughTheWireShape(_ target: RotationTarget) throws {
    let data = try JSONEncoder().encode(RotateParams(paneId: "p1", target: target))
    let decoded = try JSONDecoder().decode(RotateParams.self, from: data)
    #expect(decoded.paneId == "p1")
    #expect(decoded.orientation == target.orientation?.rawValue)
    #expect(decoded.direction == target.direction?.rawValue)
}

@Test
func targetProjectsExactlyOneField() {
    #expect(RotationTarget.absolute(.portrait).orientation == .portrait)
    #expect(RotationTarget.absolute(.portrait).direction == nil)
    #expect(RotationTarget.relative(.right).direction == .right)
    #expect(RotationTarget.relative(.right).orientation == nil)
}

@Test
func rawInitializerPreservesTheCombinationsTheHandlerRejects() throws {
    // The raw form models a foreign client, so it must pass both-set and
    // neither-set through untouched for the handler to reject.
    let both = RotateParams(paneId: "p1", orientation: "portrait", direction: "left")
    #expect(both.orientation == "portrait")
    #expect(both.direction == "left")
    let neither = RotateParams(paneId: "p1", orientation: nil, direction: nil)
    #expect(try encoded(neither) == #"{"paneId":"p1"}"#)
}
