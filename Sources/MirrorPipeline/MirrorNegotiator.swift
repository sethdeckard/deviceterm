// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap
import Foundation

/// Starts a device display's HEVC media stream over the mirror channel and reads
/// back the feedback target. One negotiator drives one channel; the device
/// closes it after the single start response.
struct MirrorNegotiator {
    // Mirror message selectors: device-protocol literals, private to this target.
    private static let startFeature = "com.apple.coredevice.feature.startmediastream"
    private static let startAction = "com.apple.coredevice.action.mediastreamstart"

    private let channel: DeviceChannel

    init(channel: DeviceChannel) {
        self.channel = channel
    }

    /// Pull the feedback target out of the answer's `streamConfig`. Receiver
    /// Reports are required to keep the encoder alive, so a partial stream
    /// configuration is an unsupported protocol response, not a best-effort
    /// session.
    static func parseFeedbackTarget(_ streamConfig: DeviceObject?) throws -> FeedbackTarget {
        guard let streamConfig else {
            throw WireCompatibilityError.missingRequiredField(
                context: "media stream configuration", field: "streamConfig"
            )
        }
        func requiredUInt32(_ field: String) throws -> UInt32 {
            guard let value = streamConfig[field] else {
                throw WireCompatibilityError.missingRequiredField(
                    context: "media stream configuration", field: field
                )
            }
            let parsed: UInt32?
            if let signed = value.signed {
                parsed = UInt32(exactly: signed)
            } else if let unsigned = value.unsigned {
                parsed = UInt32(exactly: unsigned)
            } else {
                parsed = nil
            }
            guard let parsed else {
                throw WireCompatibilityError.invalidRequiredValue(
                    context: "media stream configuration", field: field
                )
            }
            return parsed
        }

        let rawSourcePort = try requiredUInt32("SourcePort")
        guard let sourcePort = UInt16(exactly: rawSourcePort), sourcePort != 0 else {
            throw WireCompatibilityError.invalidRequiredValue(
                context: "media stream configuration", field: "SourcePort"
            )
        }
        // The device names SSRCs from its own perspective: its RemoteSSRC is ours.
        return FeedbackTarget(
            sourcePort: sourcePort,
            localSSRC: try requiredUInt32("RemoteSSRC"),
            remoteSSRC: try requiredUInt32("LocalSSRC")
        )
    }

    /// Start an RTP/HEVC stream of a device display. Bind the host UDP receiver
    /// *before* calling; the device pushes RTP as soon as it answers.
    func start(
        receiverIP: String,
        receiverPort: UInt16,
        senderIP: String,
        displayID: Int = 1,
        timeout: UInt64 = 20,
        clientSessionID: UUID = UUID()
    ) async throws -> FeedbackTarget {
        let callID = UUID().uuidString.uppercased()
        let sessionID = UInt32.random(in: 0...UInt32.max)
        let offer = try MirrorOffer.buildVideo(callID: callID, sessionID: sessionID)
        let request: DeviceObject = .object([
            ("clientSupportedFeatures", .unsigned(140)),
            ("direction", .text("output")),
            ("negotiatorOffer", .blob([UInt8](offer))),
            ("options", .object([
                ("AVCMediaStreamNegotiatorAccessNetworkType", .object([("int", .signed(1))])),
                ("AVCMediaStreamNegotiatorTransportProtocolType", .object([("int", .signed(2))])),
                ("CoreDeviceVideoDisplayMode", .object([("string", .text("DisplayByID"))])),
                ("VideoStreamForDisplayID", .object([("int", .signed(Int64(displayID)))])),
                ("avcMediaStreamOptionClientSessionID", .object([("uuid", .identifier(clientSessionID))]))
            ])),
            ("receiverIP", .text(receiverIP)),
            ("receiverPort", .unsigned(UInt64(receiverPort))),
            ("senderIP", .text(senderIP)),
            ("timeout", .unsigned(timeout)),
            ("type", .text("video"))
        ])
        let output = try await channel.invoke(Self.startFeature, input: request, action: Self.startAction)
        return try Self.parseFeedbackTarget(output["connection"]?["streamConfig"])
    }
}
