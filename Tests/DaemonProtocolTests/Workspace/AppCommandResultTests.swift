// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

@Test
func appCommandResultRoundTripsAForwardedRPCCode() throws {
    let result = AppCommandResult.error(
        commandId: "command-1",
        code: "intent.attachFailed",
        message: "pane.create: display unavailable",
        rpcCode: -32_000
    )

    let encoded = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(AppCommandResult.self, from: encoded)

    #expect(decoded == result)
    #expect(decoded.error?.rpcCode == -32_000)
}

@Test
func appCommandResultDecodesAnErrorWithoutAForwardedRPCCode() throws {
    let encoded = Data(
        #"{"commandId":"command-1","status":"error","error":{"code":"intent.notFound","message":"missing"}}"#.utf8
    )

    let decoded = try JSONDecoder().decode(AppCommandResult.self, from: encoded)

    #expect(decoded.error?.rpcCode == nil)
}
