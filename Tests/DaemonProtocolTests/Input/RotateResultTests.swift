// SPDX-License-Identifier: GPL-3.0-or-later

@testable import DaemonProtocol
import Foundation
import Testing

@Test
func confirmedRotateResultHasStableWireShape() throws {
    let result = RotateResult(
        success: true,
        status: .confirmed,
        targetOrientation: .landscapeLeft,
        observedOrientation: .landscapeLeft
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let data = try encoder.encode(result)
    let json = try #require(String(data: data, encoding: .utf8))
    let expected =
        #"{"observedOrientation":"landscapeLeft","ok":true,"status":"confirmed","# +
        #""targetOrientation":"landscapeLeft"}"#

    #expect(json == expected)
}

@Test
func unconfirmedRotateResultCarriesTheDeadlineAndLastObservation() throws {
    let result = RotateResult(
        success: false,
        status: .unconfirmed,
        targetOrientation: .landscapeRight,
        observedOrientation: .portrait,
        deadlineMs: 4_000
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let data = try encoder.encode(result)
    let json = try #require(String(data: data, encoding: .utf8))
    let expected =
        #"{"deadlineMs":4000,"observedOrientation":"portrait","ok":false,"# +
        #""status":"unconfirmed","targetOrientation":"landscapeRight"}"#

    #expect(json == expected)
}

@Test
func rotateResultRoundTripsMissingOptionalFields() throws {
    let result = RotateResult(
        success: false,
        status: .confirmationUnsupported,
        targetOrientation: nil,
        observedOrientation: nil
    )

    let data = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(RotateResult.self, from: data)
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(decoded == result)
    #expect(!json.contains("deadlineMs"))
    #expect(!json.contains("targetOrientation"))
    #expect(!json.contains("observedOrientation"))
    #expect(!json.contains("reason"))
}

@Test
func queueBackpressureHasAMachineReadableReason() throws {
    let result = RotateResult(
        success: false,
        status: .unconfirmed,
        targetOrientation: .portraitUpsideDown,
        observedOrientation: .landscapeLeft,
        reason: .queueFull
    )

    let data = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(RotateResult.self, from: data)

    #expect(decoded == result)
    #expect(decoded.reason == .queueFull)
}
