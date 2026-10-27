// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap

/// The messages a simulator's HID daemon takes, for a caller that carries them
/// over its own transport.
///
/// A simulator runs the same HID daemon as a device and accepts the same
/// vocabulary, so these are the relay's own reports and envelopes. The service
/// names double as the daemon's Mach service names inside the simulator. A
/// session the daemon keeps must open with a request it answers; one that
/// opens with a report is torn down after each message.
///
/// Touches are addressed by touchscreen service id. The daemon serves one
/// touchscreen per screen and names each one's display in its list of
/// services, which `sessionAnchor` asks for.
package enum SimulatorHIDMessages {
    /// The service that takes touch reports.
    package static let touchService = HIDReports.touchAndKeyboardFeature

    /// The service that takes hardware-button events.
    package static let buttonService = HIDReports.buttonFeature

    /// The service that takes key events for the daemon's own keyboard.
    package static let keyboardService = HIDReports.keyboardFeature

    /// The request that opens a touch session without registering anything:
    /// it asks for the session's services, which changes nothing.
    package static func sessionAnchor() -> DeviceObject {
        HIDReports.connectedServicesRequest()
    }

    /// The touchscreen service for each display UUID, from the reply to
    /// `sessionAnchor`.
    package static func touchscreenServices(fromAnchorReply reply: DeviceObject) -> [String: UInt64] {
        HIDReports.touchscreenServices(from: reply)
    }

    /// The touchscreen service for screen `screenID` when the daemon's list of
    /// services doesn't name it, or the main touchscreen for `0`.
    package static func touchscreenServiceID(screenID: UInt32) -> UInt64 {
        HIDReports.touchscreenServiceID(screenID: screenID)
    }

    /// One contact or release of a single finger at a normalized point, on
    /// touchscreen service `serviceID`.
    package static func touch(contact: Bool, x: Double, y: Double, serviceID: UInt64) -> DeviceObject {
        let report = HIDReports.touchscreenReport(
            state: contact ? HIDReports.contactState : HIDReports.releaseState,
            x: TouchScale.native(x),
            y: TouchScale.native(y),
            timestamp: HIDReports.machTicks()
        )
        return HIDReports.sendReport(report, to: serviceID)
    }

    /// Two fingers in one report, both in contact or both lifted, on
    /// touchscreen service `serviceID`.
    package static func twoFingerTouch(
        contact: Bool,
        first: (x: Double, y: Double),
        second: (x: Double, y: Double),
        serviceID: UInt64
    ) -> DeviceObject {
        let firstState = contact ? HIDReports.contactState : HIDReports.releaseState
        let secondState = HIDReports.contactState(identity: HIDReports.secondContactIdentity, touching: contact)
        let report = HIDReports.touchscreenReport(
            contacts: [
                .init(state: firstState, x: TouchScale.native(first.x), y: TouchScale.native(first.y)),
                .init(state: secondState, x: TouchScale.native(second.x), y: TouchScale.native(second.y))
            ],
            timestamp: HIDReports.machTicks()
        )
        return HIDReports.sendReport(report, to: serviceID)
    }

    /// One contact or release of a system gesture from `edge`, which reaches
    /// SpringBoard's recognizer rather than the foreground app, on
    /// touchscreen service `serviceID`.
    package static func gestureTouch(
        contact: Bool,
        x: Double,
        y: Double,
        edge: GestureEdge,
        serviceID: UInt64
    ) -> DeviceObject {
        let report = HIDReports.touchscreenReport(
            state: contact ? HIDReports.contactState : HIDReports.releaseState,
            x: TouchScale.native(x),
            y: TouchScale.native(y),
            timestamp: HIDReports.machNanoseconds(),
            trailer: edge.trailer
        )
        return HIDReports.sendReport(report, to: serviceID)
    }

    /// One phase of a key, sent to the daemon's own keyboard. The simulator
    /// doesn't count that keyboard as attached hardware, so unlike a
    /// registered keyboard it leaves the on-screen keyboard available.
    package static func key(usage: UInt16, down: Bool) -> DeviceObject {
        HIDReports.keyboardButtonEvent(usage: usage, down: down)
    }

    /// The request that registers a virtual keyboard, which the simulator
    /// counts as attached hardware: it hides the on-screen keyboard until the
    /// keyboard is removed. Its reply carries the service id to send reports
    /// to.
    package static func registerKeyboard() -> DeviceObject {
        HIDReports.createKeyboard(serviceID: HIDReports.keyboardServiceID)
    }

    /// The service id a keyboard registration reply confirms, or nil when it
    /// confirms none. A successful registration answers with the id it
    /// registered; a reply without one isn't treated as one.
    package static func registeredKeyboardServiceID(from reply: DeviceObject) -> UInt64? {
        reply.firstValue(under: "serviceID")?.unsigned
    }

    /// The registered keyboard's report for the full set of usages held down
    /// now.
    package static func keyboard(pressed usages: Set<UInt16>, serviceID: UInt64) -> DeviceObject {
        HIDReports.sendReport(
            HIDReports.keyboardReport(usages: usages, timestamp: HIDReports.machTicks()),
            to: serviceID
        )
    }

    /// The request that removes the registered keyboard `serviceID`, bringing
    /// the on-screen keyboard back. Its reply is an error even when the
    /// removal worked.
    package static func removeKeyboard(serviceID: UInt64) -> DeviceObject {
        HIDReports.removeService(serviceID: serviceID)
    }

    /// One phase of a hardware button.
    package static func button(_ input: ButtonInput) -> DeviceObject {
        HIDReports.buttonEvent(input)
    }
}
