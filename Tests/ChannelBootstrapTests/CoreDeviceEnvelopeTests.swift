// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import ChannelBootstrap

/// The CoreDevice feature-invoke envelope: its required field set, stable key
/// order, and version descriptor.
struct CoreDeviceEnvelopeTests {
    @Test("an invoke request carries the required fields in stable order")
    func requestFieldOrder() {
        let request = CoreDeviceEnvelope.request(
            selector: "com.apple.coredevice.feature.getmediasupportinfo",
            input: .fields([]),
            action: "com.apple.coredevice.action.mediastreamgetsupportinfo",
            deviceIdentifier: "device-id",
            invocationIdentifier: "invocation-id"
        )
        guard case let .fields(entries) = request else {
            Issue.record("request was not a field map")
            return
        }
        #expect(entries.map(\.name) == [
            "CoreDevice.CoreDeviceDDIProtocolVersion",
            "CoreDevice.action",
            "CoreDevice.coreDeviceVersion",
            "CoreDevice.deviceIdentifier",
            "CoreDevice.featureIdentifier",
            "CoreDevice.input",
            "CoreDevice.invocationIdentifier",
            "CoreDevice.actionIdentifier"
        ])
        #expect(request["CoreDevice.CoreDeviceDDIProtocolVersion"] == .signed(2))
        #expect(request["CoreDevice.featureIdentifier"]
            == .text("com.apple.coredevice.feature.getmediasupportinfo"))
    }

    @Test("an invoke request omits the action field when none is given")
    func requestOmitsAbsentAction() {
        let request = CoreDeviceEnvelope.request(
            selector: "com.apple.coredevice.feature.example",
            input: .fields([]),
            action: nil,
            deviceIdentifier: "d",
            invocationIdentifier: "i"
        )
        #expect(request["CoreDevice.actionIdentifier"] == nil)
    }

    @Test("the version descriptor carries the supported protocol revision")
    func versionDescriptorShape() {
        #expect(CoreDeviceEnvelope.versionDescriptor == .object([
            ("components", .list([.unsigned(629), .unsigned(3)])),
            ("originalComponentsCount", .signed(2)),
            ("stringValue", .text("629.3"))
        ]))
    }

    @Test("output extraction unwraps the reply's output field")
    func outputExtraction() throws {
        let reply: DeviceObject = .object([("CoreDevice.output", .object([("ok", .flag(true))]))])
        #expect(try CoreDeviceEnvelope.output(from: reply) == .object([("ok", .flag(true))]))
    }

    @Test("output extraction throws when the reply has no output")
    func outputMissingThrows() {
        #expect(throws: CoreDeviceEnvelope.InvokeError.self) {
            _ = try CoreDeviceEnvelope.output(from: .object([("other", .flag(true))]))
        }
    }
}
