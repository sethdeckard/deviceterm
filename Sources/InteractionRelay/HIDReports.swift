// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap
import Foundation

/// The device-side wire vocabulary for HID, button, and orientation reports:
/// feature selectors, service ids, report byte layouts, the keyboard descriptor,
/// and the request envelopes. Every device-protocol literal in this target lives
/// here, private to it; nothing above the relay sees a selector or a report byte.
enum HIDReports {
    /// One contact in a touchscreen report: its state byte (touching bits
    /// and identity), then its device-native position.
    struct TouchscreenContact {
        let state: UInt8
        let x: UInt16
        let y: UInt16
    }

    // Feature selectors.
    static let touchAndKeyboardFeature = "com.apple.coredevice.feature.remote.universalhidservice"
    static let buttonFeature = "com.apple.coredevice.feature.remote.hid.button"
    static let orientationFeature = "com.apple.coredevice.feature.remote.devicecontrol.orientation"

    // Surface ids.
    static let mainTouchscreenServiceID: UInt64 = 257

    /// Default `_ServiceID` for the host-registered virtual keyboard. Bit 32
    /// marks it session-specific, the convention macOS uses for its mirrored
    /// peripherals.
    static let keyboardServiceID: UInt64 = 0x1_0000_2001

    // Report ids and touch phase states.
    private static let touchscreenReportID: UInt8 = 0x09
    private static let keyboardReportID: UInt8 = 0x01
    static let contactState: UInt8 = 0xC2
    static let releaseState: UInt8 = 0x02
    /// The contacts a touchscreen report has room for, in the 37 bytes
    /// between its header and its trailing fields.
    private static let maximumContacts = 7
    /// The identity of a second finger, beside the first's identity 2.
    static let secondContactIdentity: UInt8 = 3

    /// HID descriptor for the virtual keyboard: report id 1 as a 240-key bitmap,
    /// six opaque bytes, two padding bytes, the exact layout `keyboardReport`
    /// produces.
    static let keyboardDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01,
        0x05, 0x07, 0x19, 0x00, 0x29, 0xEF, 0x15, 0x00,
        0x25, 0x01, 0x75, 0x01, 0x96, 0xF0, 0x00, 0x81,
        0x02, 0x06, 0x00, 0xFF, 0x19, 0x01, 0x29, 0x06,
        0x75, 0x08, 0x95, 0x06, 0x26, 0xFF, 0x00, 0x81,
        0x02, 0x95, 0x02,
        0x81, 0x03, 0xC0
    ]

    // MARK: Surfaces
    /// The touchscreen surface for a simulator's screen `screenID`, or the
    /// main touchscreen for `0`. A simulator's HID daemon serves one
    /// touchscreen per screen, at `0x100` plus the screen id, so the main one
    /// is screen 1's. The daemon's own list of services, which names each
    /// touchscreen's display, is the better answer when there is one.
    static func touchscreenServiceID(screenID: UInt32) -> UInt64 {
        screenID == 0 ? mainTouchscreenServiceID : 0x100 | UInt64(screenID)
    }

    // MARK: Timestamps

    /// Raw mach ticks, the timestamp a plain touch report carries.
    static func machTicks() -> UInt64 {
        mach_absolute_time()
    }

    /// Mach ticks converted to real-time nanoseconds, the unit a system-gesture
    /// report must carry. The recognizer reads the timestamp to judge swipe
    /// velocity, so a deliberate drag needs real-time-scaled values; raw ticks
    /// (~42× smaller deltas on Apple Silicon) read as a fast flick → Home.
    static func machNanoseconds() -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return mach_absolute_time() &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    // MARK: Report byte layouts

    /// A 58-byte `mainTouchscreen` report (report id 0x09) for one contact.
    /// `x`/`y` are the device's uint16 normalised coordinates. A non-nil
    /// `trailer` fills report bytes 50–57, marking the report for SpringBoard's
    /// edge-gesture recognizer. A plain touch leaves the trailer zeroed;
    /// top-edge system gestures also use this form.
    static func touchscreenReport(
        state: UInt8,
        x: UInt16,
        y: UInt16,
        timestamp: UInt64,
        trailer: [UInt8]? = nil
    ) -> [UInt8] {
        touchscreenReport(
            contacts: [TouchscreenContact(state: state, x: x, y: y)],
            timestamp: timestamp,
            trailer: trailer
        )
    }

    /// A 58-byte touchscreen report carrying the first `maximumContacts`
    /// contacts in `contacts`. The report has no room for more, so any past
    /// that are dropped.
    ///
    /// Byte 1 counts the contacts carried, and each takes five bytes from byte 3: its
    /// state, then x and y. A state's top two bits mark the contact touching
    /// (`0xC0`) and its low six bits are the contact's identity, which keeps
    /// it the same finger from one report to the next. A finger is lifted by
    /// sending its identity with the touching bits clear.
    static func touchscreenReport(
        contacts: [TouchscreenContact],
        timestamp: UInt64,
        trailer: [UInt8]? = nil
    ) -> [UInt8] {
        let carried = contacts.prefix(maximumContacts)
        var report: [UInt8] = [touchscreenReportID, UInt8(carried.count), 0x05]
        for contact in carried {
            report.append(contact.state)
            report.append(UInt8(contact.x & 0xFF)); report.append(UInt8((contact.x >> 8) & 0xFF))
            report.append(UInt8(contact.y & 0xFF)); report.append(UInt8((contact.y >> 8) & 0xFF))
        }
        report.append(contentsOf: [UInt8](repeating: 0, count: 40 - report.count))
        report.append(contentsOf: [0x02, 0x00, 0x00, 0x00])
        appendTimestamp(timestamp, to: &report)
        report.append(contentsOf: trailer ?? [UInt8](repeating: 0, count: 8))
        return report
    }

    /// The state of a contact with `identity`, touching or lifted.
    static func contactState(identity: UInt8, touching: Bool) -> UInt8 {
        (touching ? 0xC0 : 0x00) | (identity & 0x3F)
    }

    /// A 39-byte virtual-keyboard report (report id 0x01). `usages` is the full
    /// pressed set, since the report is delta-less, so each send overwrites the
    /// device's pressed state. Bit `u % 8` of byte `1 + u / 8` marks usage `u`
    /// down; usages ≥ 240 can't be encoded.
    static func keyboardReport(usages: Set<UInt16>, timestamp: UInt64) -> [UInt8] {
        var report: [UInt8] = [keyboardReportID]
        var bitmap = [UInt8](repeating: 0, count: 30)
        for usage in usages where usage < 240 { bitmap[Int(usage) / 8] |= UInt8(1 << (Int(usage) % 8)) }
        report.append(contentsOf: bitmap)
        appendTimestamp(timestamp, to: &report)
        report.append(contentsOf: [0x00, 0x00])
        return report
    }

    /// Append the low 48 bits of `timestamp`, little-endian, to a report.
    private static func appendTimestamp(_ timestamp: UInt64, to report: inout [UInt8]) {
        let masked = timestamp & ((1 << 48) - 1)
        for shift in stride(from: 0, to: 48, by: 8) { report.append(UInt8((masked >> shift) & 0xFF)) }
    }

    // MARK: Request envelopes

    /// The fire-and-forget send envelope for one HID report addressed to a
    /// surface id.
    static func sendReport(_ report: [UInt8], to surfaceID: UInt64) -> DeviceObject {
        .object([
            ("featureIdentifier", .text(touchAndKeyboardFeature)),
            ("messageType", .text("Request")),
            ("payload", .object([
                ("send", .object([
                    ("_0", .blob(report)),
                    ("_1", .unsigned(surfaceID))
                ]))
            ]))
        ])
    }

    /// A request for every HID service the session has, each with its
    /// `_ServiceID` and, for a touchscreen, the `displayUUID` it serves.
    static func connectedServicesRequest() -> DeviceObject {
        .object([
            ("featureIdentifier", .text(touchAndKeyboardFeature)),
            ("messageType", .text("Request")),
            ("payload", .object([("connectedServices", .object([]))]))
        ])
    }

    /// The touchscreen service serving each display, keyed by display UUID,
    /// from a `connectedServicesRequest` reply.
    static func touchscreenServices(from reply: DeviceObject) -> [String: UInt64] {
        guard case let .list(services)? = reply["connectedServices"] else { return [:] }
        var byDisplay: [String: UInt64] = [:]
        for service in services {
            guard let display = service["displayUUID"]?.text, let id = service["_ServiceID"]?.unsigned else {
                continue
            }
            byDisplay[display] = id
        }
        return byDisplay
    }

    /// The hardware-button event for one phase of `input`.
    static func buttonEvent(_ input: ButtonInput) -> DeviceObject {
        let (usagePage, usageCode) = buttonUsage(for: input.control)
        return buttonEvent(state: input.phase == .press ? 1 : 2, usagePage: usagePage, usageCode: usageCode)
    }

    /// Consumer-page HID usage for a control. There is no separate side-button
    /// case: on a Face-ID device the side button *is* the power button, so the
    /// daemon folds both onto `.power` before the intent gets here.
    static func buttonUsage(for control: ButtonInput.Control) -> (page: UInt16, code: UInt16) {
        switch control {
        case .home:
            (0x0C, 0x40)

        case .power:
            (0x0C, 0x30)

        case .assistant:
            (0x0C, 0xCF)
        }
    }

    /// One hardware-button event.
    static func buttonEvent(state: UInt64, usagePage: UInt16, usageCode: UInt16) -> DeviceObject {
        .object([
            ("messageType", .text("IndigoButtonEvent")),
            ("payload", .object([
                ("state", .unsigned(state)),
                ("usagePage", .unsigned(UInt64(usagePage))),
                ("usageCode", .unsigned(UInt64(usageCode)))
            ])),
            ("featureIdentifier", .text(buttonFeature))
        ])
    }

    /// One relative orientation step.
    static func orientationRequest(_ direction: String) -> DeviceObject {
        .object([
            ("featureIdentifier", .text(orientationFeature)),
            ("messageType", .text("OrientationRequest")),
            ("payload", .object([
                ("rotate", .object([("_0", .text(direction))]))
            ]))
        ])
    }

    /// Register a host-side virtual keyboard with the device's HID daemon.
    ///
    /// The payload mirrors what the device's decoder requires: top-level fields
    /// are raw values, but every leaf inside `_CoreDevice_codablePropertyStorage`
    /// is wrapped in a Swift-Codable type envelope (`{int:}` / `{string:}` /
    /// `{bool:}` / `{data:}` / `{uint:}` / `{array:}` / `{dictionary:}`), since
    /// the decoder rejects raw leaves there.
    static func createKeyboard(
        serviceID: UInt64,
        product: String = "deviceterm virtual keyboard",
        manufacturer: String = "deviceterm",
        vendorID: Int64 = 0x05AC,
        productID: Int64 = 0x0250
    ) -> DeviceObject {
        func wrappedInt(_ value: Int64) -> DeviceObject { .object([("int", .signed(value))]) }
        func wrappedString(_ value: String) -> DeviceObject { .object([("string", .text(value))]) }
        let usagePair: DeviceObject = .object([
            ("DeviceUsage", wrappedInt(6)),
            ("DeviceUsagePage", wrappedInt(1))
        ])
        let storage: DeviceObject = .object([
            ("Manufacturer", wrappedString(manufacturer)),
            ("Product", wrappedString(product)),
            ("ProductID", wrappedInt(productID)),
            ("VendorID", wrappedInt(vendorID)),
            ("PrimaryUsage", wrappedInt(6)),
            ("PrimaryUsagePage", wrappedInt(1)),
            ("DeviceUsagePairs", .object([("array", .list([.object([("dictionary", usagePair)])]))])),
            ("Transport", wrappedString("USB")),
            ("ReportDescriptor", .object([("data", .blob(keyboardDescriptor))])),
            ("UniversalControlVirtualService", .object([("bool", .flag(true))])),
            ("_ServiceID", .object([("uint", .unsigned(serviceID))]))
        ])
        let topUsagePair: DeviceObject = .object([
            ("DeviceUsage", .signed(6)),
            ("DeviceUsagePage", .signed(1))
        ])
        return .object([
            ("featureIdentifier", .text(touchAndKeyboardFeature)),
            ("messageType", .text("Request")),
            ("payload", .object([
                ("createService", .object([
                    ("_0", .object([
                        ("DeviceUsagePairs", .list([topUsagePair])),
                        ("PrimaryUsage", .unsigned(6)),
                        ("PrimaryUsagePage", .unsigned(1)),
                        ("Product", .text(product)),
                        ("ProductID", .signed(productID)),
                        ("VendorID", .signed(vendorID)),
                        ("_CoreDevice_codablePropertyStorage", storage),
                        ("_ServiceID", .unsigned(serviceID))
                    ]))
                ]))
            ]))
        ])
    }
}
