// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Builds the request envelope for a CoreDevice *feature invoke* and pulls the
/// result back out of the reply.
///
/// A feature invoke wraps the caller's input in a fixed set of CoreDevice
/// fields (the DDI protocol version, the version dict, an always-empty `action`
/// map, freshly minted device/invocation identifiers, the feature selector, and
/// the input) in a stable key order the device's decoder depends on. A
/// caller-supplied action identifier is appended after them when one is given.
/// The reply carries the result under `CoreDevice.output`. These field names are
/// device-protocol literals and stay private to this target.
enum CoreDeviceEnvelope {
    enum InvokeError: Error, Sendable {
        case missingOutput
    }

    /// The CoreDevice version advertised for the supported device protocol.
    static let versionDescriptor: DeviceObject = .object([
        ("components", .list([.unsigned(629), .unsigned(3)])),
        ("originalComponentsCount", .signed(2)),
        ("stringValue", .text("629.3"))
    ])

    /// Assemble the request. Identifiers are injected so fixtures can pin a
    /// deterministic shape; production mints fresh UUIDs per call.
    static func request(
        selector: String,
        input: DeviceObject,
        action: String?,
        deviceIdentifier: String,
        invocationIdentifier: String
    ) -> DeviceObject {
        var fields: [(String, DeviceObject)] = [
            ("CoreDevice.CoreDeviceDDIProtocolVersion", .signed(2)),
            ("CoreDevice.action", .fields([])),
            ("CoreDevice.coreDeviceVersion", versionDescriptor),
            ("CoreDevice.deviceIdentifier", .text(deviceIdentifier)),
            ("CoreDevice.featureIdentifier", .text(selector)),
            ("CoreDevice.input", input),
            ("CoreDevice.invocationIdentifier", .text(invocationIdentifier))
        ]
        if let action {
            fields.append(("CoreDevice.actionIdentifier", .text(action)))
        }
        return .object(fields)
    }

    /// A request with production-minted identifiers.
    static func request(selector: String, input: DeviceObject, action: String?) -> DeviceObject {
        request(
            selector: selector,
            input: input,
            action: action,
            deviceIdentifier: UUID().uuidString.lowercased(),
            invocationIdentifier: UUID().uuidString.lowercased()
        )
    }

    /// Extract the invoke result from a reply, or throw when it is absent.
    static func output(from reply: DeviceObject) throws -> DeviceObject {
        guard let output = reply["CoreDevice.output"] else { throw InvokeError.missingOutput }
        return output
    }
}
